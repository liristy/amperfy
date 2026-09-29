import AmperfyKit
import Charts
import Combine
import SwiftUI
import UIKit

enum ListeningPanel: String, CaseIterable {
  case overview = "Overview", ranking = "Rankings", trend = "Listening Trend", top = "Period Winners", history = "Listening History"
  var title: String { rawValue.localized }
}

struct ListeningRequest: Hashable {
  var address: String
  var panel: ListeningPanel
  var kind: ListeningKind
  var filter: ListeningFilter
  var page: Int
  var refresh = 0
}

struct ListeningSnapshot {
  var count = 0
  var rankings: [ListeningKind: [ListeningRow]] = [:]
  var periods: [ListeningPeriod] = []
  var performance: [ListeningPeriod] = []
  var history: [ListeningHistoryEntry] = []
  var info: ListeningInfo?
}

@MainActor
final class ListeningModel: ObservableObject {
  @Published var address: String
  @Published var showSettings = false
  @Published var panel = ListeningPanel.overview
  @Published var snapshot: ListeningSnapshot?
  @Published var error: String?
  @Published var loading = false
  @Published var playbackError: String?
  let account: Account
  private let settingsKey: String
  private var loadID = UUID()

  init(account: Account) {
    self.account = account
    settingsKey = "listening.maloja.url." + account.ident
    address = UserDefaults.standard.string(forKey: settingsKey) ?? ""
  }

  func saveAddress(_ value: String) throws {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" :
      try ListeningAPI.normalizedURL(value).absoluteString
    UserDefaults.standard.set(normalized, forKey: settingsKey)
    address = normalized
  }

  func load(_ request: ListeningRequest) async {
    let id = UUID()
    loadID = id
    snapshot = nil
    error = nil
    guard !request.address.isEmpty else { loading = false; return }
    loading = true
    do {
      let api = ListeningAPI(baseURL: try ListeningAPI.normalizedURL(request.address))
      var result = ListeningSnapshot()
      if let entity = request.filter.entity {
        async let info = api.info(entity)
        async let pulse = api.periods("pulse", filter: request.filter, page: request.page)
        var performanceFilter = request.filter
        if performanceFilter.step == "day" { performanceFilter.step = "week" }
        async let performance = api.periods("performance", filter: performanceFilter, page: request.page)
        async let history = api.history(request.filter, page: request.page)
        result.info = try await info
        result.periods = try await pulse
        result.performance = try await performance
        result.history = try await history
        if entity.kind != .tracks { result.rankings[.tracks] = try await api.charts(.tracks, filter: request.filter) }
        if entity.kind == .artists { result.rankings[.albums] = try await api.charts(.albums, filter: request.filter) }
      } else {
        switch request.panel {
        case .overview:
          async let count = api.count(request.filter)
          async let artists = api.charts(.artists, filter: request.filter)
          async let albums = api.charts(.albums, filter: request.filter)
          async let tracks = api.charts(.tracks, filter: request.filter)
          async let pulse = api.periods("pulse", filter: request.filter)
          async let history = api.history(request.filter)
          result.count = try await count
          result.rankings = try await [.artists: artists, .albums: albums, .tracks: tracks]
          result.periods = try await pulse
          result.history = try await history
        case .ranking:
          result.rankings[request.kind] = try await api.charts(request.kind, filter: request.filter)
        case .trend:
          result.periods = try await api.periods("pulse", filter: request.filter, page: request.page)
        case .top:
          let response: ListeningList<ListeningPeriod> = try await api.get("top/" + request.kind.rawValue, filter: request.filter)
          result.periods = response.list.reversed()
        case .history:
          result.history = try await api.history(request.filter, page: request.page)
        }
      }
      try Task.checkCancellation()
      guard loadID == id else { return }
      snapshot = result
      loading = false
    } catch {
      guard loadID == id else { return }
      loading = false
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  func play(_ entity: ListeningEntity) async {
    guard entity.kind == .tracks else { return }
    let app = UIApplication.shared.delegate as! AppDelegate
    do {
      var matches = matchingSongs(entity, app: app)
      if matches.isEmpty, !app.storage.settings.user.isOfflineMode {
        try await app.getMeta(account.info).librarySyncer.searchSongs(searchText: entity.name)
        matches = matchingSongs(entity, app: app)
      }
      guard let song = matches.first else {
        playbackError = "This track was not found in the current music library.".localized
        return
      }
      app.player.play(context: PlayContext(containable: song))
    } catch { playbackError = error.localizedDescription }
  }

  private func matchingSongs(_ entity: ListeningEntity, app: AppDelegate) -> [Song] {
    app.storage.main.library.searchSongs(for: account, searchText: entity.name,
      onlyCached: app.storage.settings.user.isOfflineMode, displayFilter: .all).filter { song in
        song.title.localizedCaseInsensitiveCompare(entity.name) == .orderedSame &&
          (entity.artists.isEmpty || entity.artists.contains(where: { artist in
            song.creatorName.localizedCaseInsensitiveCompare(artist) == .orderedSame
          }))
      }.sorted { left, right in
        left.album?.name == entity.album && right.album?.name != entity.album
      }
  }
}

final class ListeningStatisticsVC: UIHostingController<ListeningStatisticsView> {
  let model: ListeningModel
  init(account: Account) {
    let model = ListeningModel(account: account)
    self.model = model
    super.init(rootView: ListeningStatisticsView(model: model))
    title = "Listening Statistics".localized
  }
  @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() {
    super.viewDidLoad()
    navigationController?.navigationBar.prefersLargeTitles = true
    navigationItem.largeTitleDisplayMode = .always
    navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "slider.horizontal.3"),
      primaryAction: UIAction { [weak self] _ in self?.model.showSettings = true })
    navigationItem.rightBarButtonItem?.accessibilityLabel = "Statistics Settings".localized
    view.backgroundColor = .systemBackground
  }
}

struct ListeningStatisticsView: View {
  @ObservedObject var model: ListeningModel
  private var panel: ListeningPanel { model.panel }
  @State private var kind = ListeningKind.artists
  @State private var filter = ListeningFilter()
  @State private var page = 0
  @State private var refresh = 0
  @State private var search = ""
  @State private var showDates = false
  @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
  @State private var until = Date()
  @State private var entityPath: [ListeningEntity] = []

  init(model: ListeningModel, panel: ListeningPanel = .overview, entity: ListeningEntity? = nil) {
    self.model = model
    model.panel = panel
    _entityPath = State(initialValue: entity.map { [$0] } ?? [])
  }

  private var request: ListeningRequest {
    var scoped = filter
    scoped.entity = entityPath.last
    return .init(address: model.address, panel: panel, kind: kind, filter: scoped, page: entityPath.isEmpty && (panel == .ranking || panel == .top) ? 0 : page, refresh: refresh)
  }
  private let ranges = ["today", "thisweek", "thismonth", "thisyear", "alltime", "custom"]
  private let rangeTitles = ["Today", "This Week", "This Month", "This Year", "All Time", "Custom Range"]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if model.address.isEmpty { setup }
        else {
          toolbar
          if let entity = entityPath.last { entityHeader(entity) }
          if model.loading { ProgressView().frame(maxWidth: .infinity, minHeight: 220) }
          else if let error = model.error { failure(error) }
          else if let data = model.snapshot { dashboard(data) }
        }
      }
      .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
    }
    .background(Color(uiColor: .systemBackground))
    .task(id: request) { await model.load(request) }
    .refreshable { await model.load(request) }
    .onChange(of: panel) { _, _ in page = 0; search = "" }
    .onChange(of: kind) { _, _ in page = 0; search = "" }
    .onChange(of: filter) { _, _ in page = 0 }
    .onChange(of: model.address) { _, _ in page = 0; entityPath = [] }
    .sheet(isPresented: $model.showSettings) { ListeningSettingsView(model: model) }
    .sheet(isPresented: $showDates) { datePicker }
    .alert("Unable to Play".localized, isPresented: Binding(get: { model.playbackError != nil }, set: { if !$0 { model.playbackError = nil } })) {
      Button("OK".localized, role: .cancel) { model.playbackError = nil }
    } message: { Text(model.playbackError ?? "") }
  }

  private var setup: some View {
    VStack(spacing: 20) {
      Image(systemName: "chart.bar.xaxis").font(.system(size: 44)).foregroundStyle(.tint)
        .frame(width: 100, height: 100).glassEffect(.regular, in: .circle)
      Text("Your Music, in Numbers".localized).font(.title2.bold())
      Text("Connect the same Maloja server used in Feishin to see your listening history across devices.".localized)
        .foregroundStyle(.secondary).multilineTextAlignment(.center)
      Button("Connect Maloja".localized) { model.showSettings = true }.buttonStyle(.glassProminent)
    }.frame(maxWidth: .infinity).padding(.vertical, 70)
  }

  private var toolbar: some View {
    VStack(spacing: 16) {
      HStack {
        if !entityPath.isEmpty {
          Button { entityPath.removeLast(); page = 0 } label: { Label("Back".localized, systemImage: "chevron.left") }.buttonStyle(.glass)
        } else {
          Menu {
            Picker("Listening Statistics".localized, selection: $model.panel) {
              ForEach(ListeningPanel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
          } label: { Label(panel.title, systemImage: "chart.bar.xaxis") }.buttonStyle(.glass)
        }
        Spacer(minLength: 4)
        Menu {
          ForEach(Array(ranges.enumerated()), id: \.offset) { index, range in
            Button(rangeTitles[index].localized) {
              if range == "custom" { showDates = true } else { filter.range = range }
            }
          }
        } label: { Label(rangeTitles[ranges.firstIndex(of: filter.range) ?? 2].localized, systemImage: "calendar") }.buttonStyle(.glass)
      }.font(.subheadline)
      if filter.range == "custom" { Text(filter.from + " – " + filter.until).font(.caption).foregroundStyle(.secondary) }
      if entityPath.isEmpty && (panel == .ranking || panel == .top) {
        Picker("Category".localized, selection: $kind) {
          ForEach(ListeningKind.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented)
      }
      if panel == .trend || panel == .top || !entityPath.isEmpty {
        VStack(spacing: 12) {
          Picker("Interval".localized, selection: $filter.step) {
            ForEach(["day", "week", "month", "year"], id: \.self) { Text($0.capitalized.localized).tag($0) }
          }.pickerStyle(.segmented)
          if panel == .trend || !entityPath.isEmpty {
            Toggle("Cumulative".localized, isOn: $filter.cumulative).font(.subheadline)
            Stepper(value: $filter.trail, in: 1...100) {
              Text("Moving Window".localized + ": \(filter.trail)").font(.subheadline)
            }
          }
        }
      }
    }
  }

  @ViewBuilder private func dashboard(_ data: ListeningSnapshot) -> some View {
    if entityPath.last != nil {
      detail(data)
    } else {
      switch panel {
      case .overview:
        metrics(data)
        chart(data.periods)
        ForEach(ListeningKind.allCases, id: \.self) { kind in
          ranking(data.rankings[kind] ?? [], kind: kind, compact: true)
        }
        history(Array(data.history.prefix(6)))
      case .ranking:
        VStack(spacing: 16) {
          TextField("Search".localized, text: $search).textFieldStyle(.roundedBorder)
            .onChange(of: search) { _, _ in page = 0 }
          let rows = (data.rankings[kind] ?? []).filter {
            search.isEmpty || ($0.entity.name + " " + $0.entity.artists.joined(separator: " ")).localizedCaseInsensitiveContains(search)
          }
          ranking(Array(rows.dropFirst(page * 50).prefix(50)), kind: kind, compact: false)
          pagination(hasNext: rows.count > (page + 1) * 50)
        }
      case .trend:
        chart(data.periods)
        DisclosureGroup("Data Table".localized) {
          ForEach(Array(data.periods.enumerated()), id: \.offset) { _, period in
            LabeledContent(period.range.description, value: (period.scrobbles ?? 0).formatted()).font(.subheadline).padding(.vertical, 4)
          }
        }
        pagination(hasNext: data.periods.count == 60)
      case .top:
        winners(data.periods)
        pagination(hasNext: data.periods.count > (page + 1) * 24)
      case .history:
        history(data.history)
        pagination(hasNext: data.history.count == 50)
      }
    }
  }

  private func metrics(_ data: ListeningSnapshot) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      metric("Listens".localized, data.count.formatted(), symbol: "headphones")
      ForEach(ListeningKind.allCases, id: \.self) { kind in
        metric(kind.title, (data.rankings[kind]?.count ?? 0).formatted(), symbol: kind.symbol)
      }
    }
  }

  private func metric(_ title: String, _ value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(.title, design: .rounded, weight: .bold)).minimumScaleFactor(0.6).lineLimit(1)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
      .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 22))
  }

  private func chart(_ periods: [ListeningPeriod]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Listening Trend".localized).font(.title3.bold())
      if periods.isEmpty { empty }
      else {
        Chart(Array(periods.enumerated()), id: \.offset) { _, period in
          BarMark(x: .value("Date".localized, Date(timeIntervalSince1970: period.range.fromstamp)),
                  y: .value("Listens".localized, period.scrobbles ?? 0))
            .foregroundStyle(Color.accentColor.gradient).cornerRadius(3)
            .accessibilityLabel(period.range.description)
            .accessibilityValue((period.scrobbles ?? 0).formatted())
        }.chartYAxis { AxisMarks(position: .leading) }.frame(height: 190)
      }
    }
  }

  private func ranking(_ rows: [ListeningRow], kind: ListeningKind, compact: Bool) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(kind.title).font(.title3.bold())
        Spacer()
        if compact {
          Button("See All".localized) { self.kind = kind; model.panel = .ranking; page = 0 }.font(.subheadline)
        }
      }
      if rows.isEmpty { empty }
      ForEach(compact ? Array(rows.prefix(5)) : rows) { row in
        HStack(spacing: 12) {
          Text(row.rank.formatted()).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
          entityRow(row.entity, caption: row.entity.artists.joined(separator: ", "), trailing: row.plays.formatted())
        }
      }
    }
  }

  private func entityRow(_ entity: ListeningEntity, caption: String, trailing: String) -> some View {
    HStack(spacing: 12) {
      Button { entityPath.append(entity); page = 0 } label: {
        HStack(spacing: 12) {
          ListeningArtwork(entity: entity, address: model.address)
          VStack(alignment: .leading, spacing: 4) {
            Text(entity.name).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
            if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
          }.frame(maxWidth: .infinity, alignment: .leading)
          if !trailing.isEmpty { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain)
      if entity.kind == .tracks { ListeningPlayButton(entity: entity, model: model) }
    }.padding(.vertical, 3)
  }

  private func history(_ entries: [ListeningHistoryEntry]) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Listening History".localized).font(.title3.bold())
      if entries.isEmpty { empty }
      ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
        let date = Date(timeIntervalSince1970: entry.time)
        if index == 0 || !Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: entries[index - 1].time)) {
          Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
        }
        entityRow(entry.entity, caption: historyCaption(entry), trailing: date.formatted(date: .omitted, time: .shortened))
      }
    }
  }

  private func historyCaption(_ entry: ListeningHistoryEntry) -> String {
    var parts = entry.track.artists
    if let album = entry.track.album?.albumtitle { parts.append(album) }
    if let duration = entry.duration { parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
    if let origin = entry.origin, !origin.isEmpty { parts.append(origin) }
    return parts.joined(separator: " · ")
  }

  private func winners(_ periods: [ListeningPeriod]) -> some View {
    VStack(alignment: .leading, spacing: 20) {
      if periods.isEmpty { empty }
      ForEach(Array(periods.dropFirst(page * 24).prefix(24).enumerated()), id: \.offset) { _, period in
        Text(period.range.description).font(.headline)
        ForEach(Array((period.top ?? []).enumerated()), id: \.offset) { _, entry in
          if let entity = try? entry.entity(kind) {
            entityRow(entity, caption: entity.artists.joined(separator: ", "), trailing: entry.scrobbles.formatted())
          }
        }
        if period.top?.isEmpty != false { empty }
      }
    }
  }

  private func entityHeader(_ entity: ListeningEntity) -> some View {
    HStack(spacing: 16) {
      ListeningArtwork(entity: entity, address: model.address, size: 84)
      VStack(alignment: .leading, spacing: 8) {
        Text(entity.kind.title).font(.caption).foregroundStyle(.secondary)
        Text(entity.name).font(.title2.bold())
        ForEach(entity.artists, id: \.self) { name in
          Button(name) { entityPath.append(.init(kind: .artists, name: name)); page = 0 }.font(.subheadline)
        }
      }
      Spacer(minLength: 0)
      if entity.kind == .tracks { ListeningPlayButton(entity: entity, model: model) }
    }
  }

  @ViewBuilder private func detail(_ data: ListeningSnapshot) -> some View {
    if let info = data.info {
      Text("Lifetime Statistics".localized).font(.headline)
      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
        metric("Listens".localized, info.scrobbles.formatted(), symbol: "headphones")
        metric("Rankings".localized, info.position.map { "#\($0)" } ?? "-", symbol: "chart.bar")
        metric("Weeks at Number One".localized, info.topweeks.map { String($0) } ?? "-", symbol: "crown")
        metric("Certification".localized, info.certification?.capitalized ?? "-", symbol: "seal")
      }
      if let medals = info.medals {
        ForEach(["gold", "silver", "bronze"], id: \.self) { medal in
          if let awards = medals[medal], !awards.isEmpty {
            Label(medal.capitalized.localized + ": " + awards.joined(separator: ", "), systemImage: "medal").font(.caption)
          }
        }
      }
      let related = Array(Set((info.associated ?? []) + (info.replace.map { [$0] } ?? []))).sorted()
      if !related.isEmpty {
        Text("Associated Artists".localized).font(.headline)
        ForEach(related, id: \.self) { name in
          Button(name) { entityPath.append(.init(kind: .artists, name: name)); page = 0 }.buttonStyle(.glass)
        }
      }
    }
    chart(data.periods)
    DisclosureGroup("Ranking Over Time".localized) {
      ForEach(Array(data.performance.enumerated()), id: \.offset) { _, period in
        LabeledContent(period.range.description, value: period.rank.map { "#\($0)" } ?? "-").font(.subheadline).padding(.vertical, 6)
      }
    }
    ForEach([ListeningKind.tracks, .albums], id: \.self) { kind in
      if let rows = data.rankings[kind] { ranking(rows, kind: kind, compact: false) }
    }
    history(data.history)
    pagination(hasNext: data.history.count == 50 || data.periods.count == 60 || data.performance.count == 60)
  }

  private var empty: some View {
    Text("No listens in this period.".localized).font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20)
  }

  private func failure(_ message: String) -> some View {
    ContentUnavailableView {
      Label("Unable to Load Statistics".localized, systemImage: "wifi.exclamationmark")
    } description: { Text(message) } actions: {
      Button("Retry".localized) { refresh += 1 }.buttonStyle(.glass)
      Button("Statistics Settings".localized) { model.showSettings = true }.buttonStyle(.glass)
    }
  }

  private func pagination(hasNext: Bool) -> some View {
    HStack {
      Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }
        .disabled(page == 0).accessibilityLabel("Previous Page".localized)
      Spacer()
      Text("Page".localized + " \(page + 1)").font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button { page += 1 } label: { Image(systemName: "chevron.right") }
        .disabled(!hasNext).accessibilityLabel("Next Page".localized)
    }.buttonStyle(.glass)
  }

  private var datePicker: some View {
    NavigationStack {
      Form {
        DatePicker("From".localized, selection: $from, in: ...until, displayedComponents: .date)
        DatePicker("Until".localized, selection: $until, in: from..., displayedComponents: .date)
      }.navigationTitle("Custom Range".localized)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel".localized) { showDates = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Apply".localized) {
              let formatter = DateFormatter()
              formatter.locale = Locale(identifier: "en_US_POSIX")
              formatter.dateFormat = "yyyy-MM-dd"
              filter.from = formatter.string(from: from)
              filter.until = formatter.string(from: until)
              filter.range = "custom"
              showDates = false
            }
          }
        }
    }.presentationDetents([.medium])
  }
}

private struct ListeningArtwork: View {
  let entity: ListeningEntity
  let address: String
  var size: CGFloat = 48
  var body: some View {
    AsyncImage(url: (try? ListeningAPI.normalizedURL(address)).flatMap { ListeningAPI(baseURL: $0).artwork(entity) }) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      ZStack {
        Color.accentColor.opacity(0.09)
        Image(systemName: entity.kind.symbol).foregroundStyle(.secondary)
      }
    }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: entity.kind == .artists ? size / 2 : 8))
      .accessibilityHidden(true)
  }
}

private struct ListeningPlayButton: View {
  let entity: ListeningEntity
  @ObservedObject var model: ListeningModel
  @State private var busy = false
  var body: some View {
    Button {
      busy = true
      Task { await model.play(entity); busy = false }
    } label: {
      if busy { ProgressView() } else { Image(systemName: "play.fill").frame(width: 24, height: 28) }
    }.buttonStyle(.glass).disabled(busy).accessibilityLabel("Play".localized + " · " + entity.name)
  }
}

private struct ListeningSettingsView: View {
  @ObservedObject var model: ListeningModel
  @Environment(\.dismiss) private var dismiss
  @State private var address = ""
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("https://maloja.example.com", text: $address)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Maloja Server".localized)
        } header: { Text("Maloja Server".localized) } footer: {
          Text("Use the same address as Feishin. Statistics come from Maloja; your existing music server continues to handle playback and scrobbling.".localized)
        }
        if let error { Text(error).foregroundStyle(.red) }
      }.navigationTitle("Statistics Settings".localized)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel".localized) { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save".localized) {
              do { try model.saveAddress(address); dismiss() } catch { self.error = error.localizedDescription }
            }
          }
        }
    }.onAppear { address = model.address }.presentationDetents([.medium, .large])
  }
}
