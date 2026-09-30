#if DEBUG
import AmperfyKit
import UIKit

@MainActor
enum ListeningStatisticsSmoke {
  private static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "ListeningStatisticsSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  }

  static func run(on tabHost: TabBarVC) async throws {
    let normalized = try ListeningAPI.normalizedURL(" https://example.com/maloja///?ignored=1#fragment ")
    try check(normalized.absoluteString == "https://example.com/maloja", "Maloja subpath normalization failed")
    for invalid in ["file:///tmp/music", "ftp://example.com", "https://user:pass@example.com", "not a URL"] {
      do {
        _ = try ListeningAPI.normalizedURL(invalid)
        throw NSError(domain: "ListeningStatisticsSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Accepted invalid address"])
      } catch ListeningError.invalidURL { }
    }
    let api = ListeningAPI(baseURL: URL(string: "http://127.0.0.1:8765")!)
    var filter = ListeningFilter()
    try check(try await api.count(filter) == 328, "Listening count mismatch")
    let artists = try await api.charts(.artists, filter: filter)
    let albums = try await api.charts(.albums, filter: filter)
    let tracks = try await api.charts(.tracks, filter: filter)
    try check(artists.count == 4 && albums.count == 4 && tracks.count == 55, "Charts lost songs or paging candidates")
    try check(tracks[0].entity.remoteID == "1" && albums[0].entity.remoteID == "1", "Numeric/string IDs not normalized")
    let first = try await api.history(filter)
    let second = try await api.history(filter, page: 1)
    try check(first.count == 50 && second.count == 1 && second[0].time < first.last!.time,
              "History paging duplicated records")
    try check(first[0].entity.album == first[1].entity.album, "Album string/object variants not supported")
    let periods = try await api.periods("pulse", filter: filter)
    try check(periods.count == 12 && periods.first!.range.fromstamp < periods.last!.range.fromstamp, "Trend order is wrong")
    let info = try await api.info(artists[0].entity)
    try check(info.position == 2 && info.medals?["gold"]?.count == 1, "Lifetime awards missing")
    filter.entity = .init(kind: .tracks, name: "A&B / 音乐", artists: ["Artist A", "Artist B"])
    filter.range = "custom"; filter.from = "2026-09-01"; filter.until = "2026-09-29"
    filter.cumulative = true; filter.trail = 7
    let url = try api.url("pulse", filter: filter)
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    try check(items.filter { $0.name == "trackartist" }.count == 2 &&
              items.contains(.init(name: "title", value: "A&B / 音乐")) &&
              items.contains(.init(name: "from", value: "2026/09/01")) &&
              items.contains(.init(name: "cumulative", value: "yes")), "Entity/date filters were corrupted")
    filter = .init(range: "empty")
    try check(try await api.history(filter).isEmpty, "Empty state was not preserved")
    filter.range = "invalid"
    do { _ = try await api.count(filter); try check(false, "Error response accepted as a count") }
    catch ListeningError.invalidResponse { }
    filter.range = "unauthorized"
    do { _ = try await api.history(filter); try check(false, "HTTP error accepted") }
    catch ListeningError.http(401) { }

    try check(tabHost.tabs.map(\.identifier) == ["Tabs.Home", "Tabs.Library", "Tabs.Listening", "Tabs.Search"],
              "Four tabs are not in the requested order")
    try check(tabHost.tabs.last.map { !($0 is UISearchTab) } == true, "Search is detached from the native capsule")
    let previousTab = tabHost.selectedTab
    tabHost.selectedTab = tabHost.tabs[2]
    tabHost.view.layoutIfNeeded()
    guard let navigation = tabHost.selectedViewController as? UINavigationController,
          let host = navigation.topViewController as? ListeningStatisticsVC else {
      try check(false, "Statistics tab did not open"); return
    }
    host.model.address = "http://127.0.0.1:8765"
    let model = host.model
    for panel in ListeningPanel.allCases {
      host.rootView = ListeningStatisticsView(model: model, panel: panel)
      try await Task.sleep(for: .milliseconds(150))
      for _ in 0..<60 {
        if model.snapshot != nil && !model.loading { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      try check(model.snapshot != nil && model.error == nil, "Statistics panel failed: \(panel.rawValue)")
      // Exercise every data contract even if SwiftUI preserves the current panel's state.
      let probe = ListeningModel(account: model.account)
      let request = ListeningRequest(address: model.address, panel: panel, kind: .tracks, filter: .init(), page: 0)
      await probe.load(request)
      try check(probe.snapshot != nil && probe.error == nil, "Panel API failed: \(panel.rawValue)")
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      try capture(tabHost, name: "player-statistics-\(panel)")
    }
    let probe = ListeningModel(account: model.account)
    for entity in [artists[0].entity, albums[0].entity, tracks[0].entity] {
      var detailFilter = ListeningFilter(); detailFilter.entity = entity
      await probe.load(.init(address: model.address, panel: .overview, kind: .artists, filter: detailFilter, page: 0))
      try check(probe.snapshot?.info?.scrobbles == 512 && probe.snapshot?.performance.count == 12,
                "Entity detail failed: \(entity.kind)")
    }
    await probe.play(tracks[0].entity)
    let app = UIApplication.shared.delegate as! AppDelegate
    try check(app.player.currentlyPlaying?.title == "测试歌曲" && probe.playbackError == nil, "History track playback failed")
    await probe.play(.init(kind: .tracks, name: "Missing fixture song", artists: ["Nobody"]))
    try check(probe.playbackError != nil, "Missing song was silently ignored")
    model.panel = .overview
    try await Task.sleep(for: .milliseconds(600))
    func descendants(_ view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap { descendants($0) } }
    guard let scroll = descendants(host.view).compactMap({ $0 as? UIScrollView }).first(where: {
      $0.bounds.height > 250 && $0.contentSize.height > $0.bounds.height + 250
    }) else { try check(false, "Statistics scroll view unavailable"); return }
    scroll.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
    try await Task.sleep(for: .milliseconds(250))
    let offset = scroll.contentOffset
    model.openEntity?(artists[0].entity, .init())
    try await Task.sleep(for: .milliseconds(700))
    guard let detail = navigation.topViewController as? ListeningStatisticsVC else {
      try check(false, "Entity did not use native navigation"); return
    }
    try check(detail !== host && navigation.viewControllers.count == 2 &&
      navigation.interactivePopGestureRecognizer?.isEnabled == true &&
      !navigation.isNavigationBarHidden, "Native back navigation or edge swipe unavailable")
    try await Task.sleep(for: .milliseconds(700))
    try capture(tabHost, name: "player-statistics-detail")
    navigation.popViewController(animated: true)
    try await Task.sleep(for: .milliseconds(700))
    try check(navigation.topViewController === host && abs(scroll.contentOffset.y - offset.y) < 1,
              "Statistics detail return lost the original scroll position")
    let statisticsTab = tabHost.selectedTab
    tabHost.miniPlayer?.openPlayerView()
    try await Task.sleep(for: .milliseconds(800))
    guard let presenter = AppDelegate.mainWindowHostVC as? UIViewController,
          let popup = presenter.presentedViewController as? PopupPlayerVC else {
      try check(false, "Player did not open from statistics"); return
    }
    popup.dismiss(animated: true)
    try await Task.sleep(for: .milliseconds(900))
    try check(tabHost.selectedTab === statisticsTab && navigation.topViewController === host &&
              abs(scroll.contentOffset.y - offset.y) < 1, "Closing the player changed the originating page or scroll position")
    try capture(tabHost, name: "player-statistics-return")
    tabHost.selectedTab = previousTab
    print("Listening statistics passed: URL validation, filters, count, three rankings, trends, winners, history paging, details, errors and playback; four native tabs and exact return position verified")
  }

  private static func capture(_ host: UIViewController, name: String) throws {
    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
      host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
    }
    try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name + ".png"))
  }
}
#endif
