import AmperfyKit
import Foundation

// Maloja's public read API, matching the local Feishin listening dashboard.
// No music-server credentials are sent to the statistics server.
struct ListeningEntity: Hashable, Identifiable, Sendable {
  var kind: ListeningKind
  var name: String
  var artists: [String] = []
  var album: String?
  var remoteID: String?
  var id: String { "\(kind.rawValue):\(name):\(artists.joined(separator: "\u{1f}"))" }
}

enum ListeningKind: String, CaseIterable, Sendable {
  case artists, albums, tracks
  var title: String {
    switch self {
    case .artists: "Artists".localized
    case .albums: "Albums".localized
    case .tracks: "Songs".localized
    }
  }
  var singular: String { String(rawValue.dropLast()) }
  var symbol: String {
    switch self { case .artists: "music.mic"; case .albums: "square.stack"; case .tracks: "music.note" }
  }
}

struct ListeningFilter: Hashable, Sendable {
  var range = "thismonth"
  var from = ""
  var until = ""
  var step = "day"
  var trail = 1
  var cumulative = false
  var entity: ListeningEntity?

  var query: [URLQueryItem] {
    var items = [URLQueryItem]()
    if range == "custom" {
      items += [.init(name: "from", value: from.replacingOccurrences(of: "-", with: "/")),
                .init(name: "until", value: until.replacingOccurrences(of: "-", with: "/"))]
    } else if range != "alltime" { items.append(.init(name: "in", value: range)) }
    items += [.init(name: "step", value: step), .init(name: "trail", value: String(trail))]
    if cumulative { items.append(.init(name: "cumulative", value: "yes")) }
    if let entity {
      if entity.kind == .artists {
        items += [.init(name: "artist", value: entity.name), .init(name: "associated", value: "yes")]
      } else {
        items.append(.init(name: entity.kind == .albums ? "albumtitle" : "title", value: entity.name))
        items += entity.artists.map { .init(name: entity.kind == .albums ? "albumartist" : "trackartist", value: $0) }
      }
    }
    return items
  }
}

enum ListeningError: LocalizedError {
  case invalidURL, invalidResponse, http(Int)
  var errorDescription: String? {
    switch self {
    case .invalidURL: "Enter a valid HTTP or HTTPS Maloja address without a username or password.".localized
    case .invalidResponse: "The server did not return valid Maloja statistics.".localized
    case .http(let code): "Maloja request failed".localized + " (HTTP \(code))"
    }
  }
}

struct ListeningAPI: Sendable {
  let baseURL: URL
  var session = URLSession.shared

  static func normalizedURL(_ text: String) throws -> URL {
    guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
          let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else {
      throw ListeningError.invalidURL
    }
    parts.query = nil
    parts.fragment = nil
    while parts.path.hasSuffix("/") { parts.path.removeLast() }
    guard let url = parts.url else { throw ListeningError.invalidURL }
    return url
  }

  func url(_ endpoint: String, filter: ListeningFilter? = nil,
           extra: [URLQueryItem] = []) throws -> URL {
    let path = baseURL.appendingPathComponent("apis/mlj_1/" + endpoint)
    guard var parts = URLComponents(url: path, resolvingAgainstBaseURL: false) else { throw ListeningError.invalidURL }
    parts.queryItems = (filter?.query ?? []) + extra
    guard let url = parts.url else { throw ListeningError.invalidURL }
    return url
  }

  func get<T: Decodable>(_ endpoint: String, filter: ListeningFilter? = nil,
                          extra: [URLQueryItem] = []) async throws -> T {
    var request = URLRequest(url: try url(endpoint, filter: filter, extra: extra))
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw ListeningError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else { throw ListeningError.http(response.statusCode) }
    try Task.checkCancellation()
    return try JSONDecoder().decode(T.self, from: data)
  }

  func count(_ filter: ListeningFilter) async throws -> Int {
    let response: ListeningCount = try await get("numscrobbles", filter: filter)
    guard response.amount >= 0 else { throw ListeningError.invalidResponse }
    return response.amount
  }

  func charts(_ kind: ListeningKind, filter: ListeningFilter) async throws -> [ListeningRow] {
    let response: ListeningList<ListeningChartEntry> = try await get("charts/" + kind.rawValue, filter: filter)
    return try response.list.enumerated().map { index, entry in
      ListeningRow(entity: try entry.entity(kind), plays: entry.scrobbles, rank: entry.rank ?? index + 1)
    }
  }

  func periods(_ endpoint: String, filter: ListeningFilter, page: Int = 0) async throws -> [ListeningPeriod] {
    let response: ListeningList<ListeningPeriod> = try await get(endpoint, filter: filter, extra: [
      .init(name: "page", value: String(page)), .init(name: "perpage", value: "60"), .init(name: "reverse", value: "yes"),
    ])
    return response.list.reversed()
  }

  func history(_ filter: ListeningFilter, page: Int = 0) async throws -> [ListeningHistoryEntry] {
    let response: ListeningList<ListeningHistoryEntry> = try await get("scrobbles", filter: filter, extra: [
      .init(name: "page", value: String(page)), .init(name: "perpage", value: "50"),
    ])
    return response.list
  }

  func info(_ entity: ListeningEntity) async throws -> ListeningInfo {
    var filter = ListeningFilter(range: "alltime")
    filter.entity = entity
    return try await get(entity.kind.singular + "info", filter: filter)
  }

  func artwork(_ entity: ListeningEntity) -> URL? {
    guard let id = entity.remoteID,
          var parts = URLComponents(url: baseURL.appendingPathComponent("image"), resolvingAgainstBaseURL: false) else { return nil }
    parts.queryItems = [.init(name: entity.kind.singular + "_id", value: id)]
    return parts.url
  }
}

struct ListeningList<T: Decodable>: Decodable {
  let list: [T]
  private enum CodingKeys: String, CodingKey { case status, list }
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard ["ok", "success"].contains(try container.decode(String.self, forKey: .status)) else { throw ListeningError.invalidResponse }
    list = try container.decode([T].self, forKey: .list)
  }
}

struct ListeningCount: Decodable {
  let amount: Int
  private enum CodingKeys: String, CodingKey { case status, amount }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard ["ok", "success"].contains(try values.decode(String.self, forKey: .status)) else { throw ListeningError.invalidResponse }
    amount = try values.decode(Int.self, forKey: .amount)
  }
}

struct ListeningID: Decodable, Sendable {
  let value: String
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let number = try? container.decode(Int.self) { value = String(number) }
    else { value = try container.decode(String.self) }
  }
}

struct ListeningAlbum: Decodable, Sendable {
  let albumtitle: String
  let artists: [String]?
  private enum CodingKeys: String, CodingKey { case albumtitle, artists }
  init(from decoder: Decoder) throws {
    if let title = try? decoder.singleValueContainer().decode(String.self) {
      albumtitle = title; artists = nil
    } else {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      albumtitle = try values.decode(String.self, forKey: .albumtitle)
      artists = try values.decodeIfPresent([String].self, forKey: .artists)
    }
  }
}

struct ListeningTrack: Decodable, Sendable {
  let title: String
  let artists: [String]
  let album: ListeningAlbum?
}

struct ListeningChartEntry: Decodable, Sendable {
  let artist: String?
  let album: ListeningAlbum?
  let track: ListeningTrack?
  let artist_id: ListeningID?
  let album_id: ListeningID?
  let track_id: ListeningID?
  let scrobbles: Int
  let rank: Int?
  func entity(_ kind: ListeningKind) throws -> ListeningEntity {
    guard scrobbles >= 0 else { throw ListeningError.invalidResponse }
    switch kind {
    case .artists:
      guard let artist else { throw ListeningError.invalidResponse }
      return .init(kind: kind, name: artist, remoteID: artist_id?.value)
    case .albums:
      guard let album else { throw ListeningError.invalidResponse }
      return .init(kind: kind, name: album.albumtitle, artists: album.artists ?? [], remoteID: album_id?.value)
    case .tracks:
      guard let track else { throw ListeningError.invalidResponse }
      return .init(kind: kind, name: track.title, artists: track.artists, album: track.album?.albumtitle, remoteID: track_id?.value)
    }
  }
}

struct ListeningRow: Identifiable, Sendable {
  let entity: ListeningEntity
  let plays: Int
  let rank: Int
  var id: String { entity.id }
}

struct ListeningPeriod: Decodable, Sendable {
  struct Range: Decodable, Sendable { let description: String; let fromstamp: Double; let tostamp: Double }
  let range: Range
  let scrobbles: Int?
  let rank: Int?
  let top: [ListeningChartEntry]?
}

struct ListeningHistoryEntry: Decodable, Sendable {
  let time: Double
  let duration: Double?
  let origin: String?
  let track: ListeningTrack
  let track_id: ListeningID?
  var entity: ListeningEntity {
    .init(kind: .tracks, name: track.title, artists: track.artists, album: track.album?.albumtitle, remoteID: track_id?.value)
  }
}

struct ListeningInfo: Decodable, Sendable {
  let scrobbles: Int
  let position: Int?
  let topweeks: Int?
  let certification: String?
  let medals: [String: [String]]?
  let associated: [String]?
  let replace: String?
}
