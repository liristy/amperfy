//
//  BackendApi.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 19.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import CoreData
import CoreMedia
import Foundation

// MARK: - ParsedObjectType

public enum ParsedObjectType: Sendable {
  case artist
  case album
  case song
  case playlist
  case genre
  case podcast
  case cache
}

// MARK: - ParsedObjectNotifiable

public protocol ParsedObjectNotifiable {
  func notifyParsedObject(ofType parsedObjectType: ParsedObjectType)
}

// MARK: - SyncCallbacks

public protocol SyncCallbacks: ParsedObjectNotifiable, Sendable {
  nonisolated func notifySyncStarted(ofType parsedObjectType: ParsedObjectType, totalCount: Int)
}

// MARK: - ThreadPerformanceMonitor

public protocol ThreadPerformanceMonitor: Sendable {
  var shouldSlowDownExecution: Bool { get }
  var isInForeground: Bool { get set }
}

// MARK: - ThreadPerformanceObserver

final public class ThreadPerformanceObserver: ThreadPerformanceMonitor, Sendable {
  public static let shared = ThreadPerformanceObserver()

  private let _isInForeground = Atomic<Bool>(wrappedValue: true)
  public var isInForeground: Bool {
    get { _isInForeground.wrappedValue }
    set { _isInForeground.wrappedValue = newValue }
  }

  public var shouldSlowDownExecution: Bool {
    !isInForeground
  }
}

// MARK: - NowPlayingSongPosition

public enum NowPlayingSongPosition {
  case start
  case end
}

// MARK: - APIDataResponse

public final class APIDataResponse: Sendable {
  public let data: Data
  public let url: URL?

  init(data: Data, url: URL?) {
    self.data = data
    self.url = url
  }
}

// MARK: - LyricsList

public struct LyricsList: Sendable {
  public var lyrics = [StructuredLyrics]()
  var translations = [StructuredLyrics]()

  public func getFirstSyncedLyricsOrUnsyncedAsDefault() -> StructuredLyrics? {
    let nonempty = lyrics.filter { !$0.line.isEmpty }
    let wordSynced = nonempty.first { lyric in
      lyric.synced && lyric.line.contains { line in
        !line.cues.isEmpty || line.vocals.contains { !$0.cues.isEmpty }
      }
    }
    guard var main = wordSynced ?? nonempty.first(where: { $0.synced }) ?? nonempty.first else {
      return nil
    }
    let language = Locale.current.language.languageCode?.identifier
    let preferred = translations.filter {
      Locale(identifier: $0.lang).language.languageCode?.identifier == language
    }
    for track in preferred + translations {
      let matches = main.alignTranslation(track)
      guard !matches.isEmpty else { continue }
      for (index, translation) in matches { main.line[index].translation = translation }
      break
    }
    return main
  }
}

// MARK: - StructuredLyrics

public struct StructuredLyrics: Sendable {
  /// required
  public var lang =
    "" // The lyrics language (ideally ISO 639). If the language is unknown (e.g. lrc file), the server must return und (ISO standard) or xxx (common value for taggers)
  public var synced = false // True if the lyrics are synced, false otherwise
  public var line =
    [LyricsLine]() // The actual lyrics. Ordered by start time (synced) or appearance order (unsynced)
  /// optional
  public var displayArtist: String? // The artist name to display. This could be the localized name, or any other value
  public var displayTitle: String? // The title to display. This could be the song title (localized), or any other value
  public var offset =
    0 // The offset to apply to all lyrics, in milliseconds. Positive means lyrics appear sooner, negative means later. If not included, the offset must be assumed to be 0
  public init() {}

  public func adjustedTime(for time: CMTime) -> CMTime {
    CMTimeAdd(time, CMTime(value: Int64(offset), timescale: 1_000))
  }

  public func activeLineIndex(at time: CMTime) -> Int? {
    guard synced, time.seconds.isFinite else { return nil }
    let adjustedTime = self.adjustedTime(for: time)
    return line.lastIndex { lyric in
      guard let start = lyric.start else { return false }
      return CMTimeCompare(CMTime(value: Int64(start), timescale: 1_000), adjustedTime) <= 0
    }
  }

  fileprivate func alignTranslation(_ track: StructuredLyrics) -> [Int: LyricVocal] {
    var matches = [Int: (distance: Double, vocal: LyricVocal)]()
    let starts = line.enumerated().compactMap { index, lyric in
      lyric.start.map { (index: index, time: Double($0) - Double(offset)) }
    }.sorted { $0.time < $1.time }
    var nearestIndex = 0
    let trackLines = synced && track.synced
      ? track.line.enumerated().sorted { ($0.element.start ?? 0) < ($1.element.start ?? 0) }
      : Array(track.line.enumerated())
    for (index, lyric) in trackLines {
      let text = lyric.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let match: (index: Int, distance: Double)
      if synced, track.synced {
        guard let start = lyric.start, !starts.isEmpty else { continue }
        let time = Double(start) - Double(track.offset)
        while nearestIndex + 1 < starts.count, starts[nearestIndex + 1].time <= time {
          nearestIndex += 1
        }
        let current = starts[nearestIndex]
        let next = starts.dropFirst(nearestIndex + 1).first
        let distance = abs(current.time - time)
        if let next, abs(next.time - time) < distance {
          match = (next.index, abs(next.time - time))
        } else {
          match = (current.index, distance)
        }
      } else {
        guard track.line.count == line.count else { continue }
        match = (index, 0)
      }
      guard match.distance <= 1_500, match.distance < (matches[match.index]?.distance ?? .infinity),
            text != line[match.index].value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        continue
      }
      let delta = offset - track.offset
      var vocal = lyric.vocals.first ?? LyricVocal(
        value: lyric.value, start: lyric.start, end: nil, cues: lyric.cues, agentID: nil
      )
      if synced, track.synced {
        vocal.start = vocal.start.map { $0 + delta }
        vocal.end = vocal.end.map { $0 + delta }
        vocal.cues = vocal.cues.map {
          LyricCue(start: $0.start + delta, end: $0.end.map { $0 + delta }, range: $0.range)
        }
      } else {
        vocal.start = nil
        vocal.end = nil
        vocal.cues = []
      }
      matches[match.index] = (match.distance, vocal)
    }
    return matches.mapValues(\.vocal)
  }
}

// MARK: - LyricsLine

public struct LyricsLine: Equatable, Sendable {
  public var start: Int? // The start time of the lyrics, relative to the start time of the track, in milliseconds. If this is not part of synced lyrics, start must be omitted
  public var value = "" // The actual text of this line
  public internal(set) var cues = [LyricCue]()
  public internal(set) var vocals = [LyricVocal]()
  public internal(set) var translation: LyricVocal?

  public init() {}
  public var startTime: CMTime {
    guard let start = start else { return CMTime(value: Int64(0), timescale: 1) }
    return CMTime(value: Int64(start), timescale: 1_000)
  }
}

public struct LyricVocal: Equatable, Sendable {
  public let value: String
  public internal(set) var start: Int?
  public internal(set) var end: Int?
  public internal(set) var cues: [LyricCue]
  public let agentID: String?
}

public struct LyricCue: Equatable, Sendable {
  public let start: Int
  public let end: Int?
  public let range: NSRange // UTF-16 range in LyricsLine.value
}

// MARK: - LibrarySyncer

public protocol LibrarySyncer: Sendable {
  @MainActor
  func syncInitial(statusNotifyier: SyncCallbacks?) async throws
  @MainActor
  func sync(genre: Genre) async throws
  @MainActor
  func sync(artist: Artist) async throws
  @MainActor
  func sync(album: Album) async throws
  @MainActor
  func syncAlbumDetail(_ album: Album) async throws
  @MainActor
  func sync(song: Song) async throws
  @MainActor
  func sync(podcast: Podcast) async throws
  @MainActor
  func syncNewestAlbums(offset: Int, count: Int) async throws
  @MainActor
  func syncRecentAlbums(offset: Int, count: Int) async throws
  @MainActor
  func syncNewestPodcastEpisodes() async throws
  @MainActor
  func syncFavoriteLibraryElements() async throws
  @MainActor
  func syncRadios() async throws
  @MainActor
  func syncDownPlaylistsWithoutSongs() async throws
  @MainActor
  func syncDown(playlist: Playlist) async throws
  @MainActor
  func syncUpload(playlistToUpdateName playlist: Playlist) async throws
  @MainActor
  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws
  @MainActor
  func syncUpload(playlistToDeleteSong playlist: Playlist, index: Int) async throws
  @MainActor
  func syncUpload(playlistToUpdateOrder playlist: Playlist) async throws
  @MainActor
  func syncUpload(playlistIdToDelete id: String) async throws
  @MainActor
  func syncDownPodcastsWithoutEpisodes() async throws
  @MainActor
  func searchArtists(searchText: String) async throws
  @MainActor
  func searchAlbums(searchText: String) async throws
  @MainActor
  func searchSongs(searchText: String) async throws
  @MainActor
  func syncMusicFolders() async throws
  @MainActor
  func syncIndexes(musicFolder: MusicFolder) async throws
  @MainActor
  func sync(directory: Directory) async throws
  @MainActor
  func requestRandomSongs(playlist: Playlist, count: Int) async throws
  @MainActor
  func requestSimilarSongs(song: Song, count: Int) async throws -> [Song]
  @MainActor
  func requestPodcastEpisodeDelete(podcastEpisode: PodcastEpisode) async throws
  @MainActor
  func syncNowPlaying(song: Song, songPosition: NowPlayingSongPosition) async throws
  @MainActor
  func scrobble(song: Song, date: Date?) async throws
  @MainActor
  func setRating(song: Song, rating: Int) async throws
  @MainActor
  func setRating(album: Album, rating: Int) async throws
  @MainActor
  func setRating(artist: Artist, rating: Int) async throws
  @MainActor
  func setFavorite(song: Song, isFavorite: Bool) async throws
  @MainActor
  func setFavorite(album: Album, isFavorite: Bool) async throws
  @MainActor
  func setFavorite(artist: Artist, isFavorite: Bool) async throws
  @MainActor
  func parseLyrics(relFilePath: URL) async throws -> LyricsList
}

public extension LibrarySyncer {
  @MainActor
  func syncAlbumDetail(_ album: Album) async throws {
    try await sync(album: album)
  }
}

// MARK: - AbstractBackgroundLibrarySyncer

protocol AbstractBackgroundLibrarySyncer {
  var isActive: Bool { get }
  func stop()
}

// MARK: - CleansedURL

final public class CleansedURL: Sendable {
  private let urlString: String

  init(urlString: String) {
    self.urlString = urlString
  }

  var description: String {
    urlString
  }
}

extension URL {
  nonisolated func asCleansedURL(cleanser: URLCleanser) -> CleansedURL {
    cleanser.cleanse(url: self)
  }
}

// MARK: - URLCleanser

public protocol URLCleanser: Sendable {
  func cleanse(url: URL?) -> CleansedURL
}

// MARK: - TranscodingInfo

public struct TranscodingInfo {
  var format: CacheTranscodingFormatPreference?
  var bitrate: StreamingMaxBitratePreference?

  var description: String {
    "Format: \(format?.description ?? "-"), Bitrate: \(bitrate?.description ?? "-")"
  }
}

// MARK: - BackendApi

public protocol BackendApi: URLCleanser, Sendable {
  var clientApiVersion: String { get }
  var serverApiVersion: String { get }
  var httpHeaders: [String: String] { get }
  func provideCredentials(credentials: LoginCredentials)
  func isAuthenticationValid(credentials: LoginCredentials) async throws
  func generateUrl(forDownloadingPlayable playableInfo: AbstractPlayableInfo) async throws -> URL
  func generateUrl(
    forStreamingPlayable playableInfo: AbstractPlayableInfo,
    maxBitrate: StreamingMaxBitratePreference,
    formatPreference: StreamingFormatPreference
  ) async throws -> URL
  func generateUrl(forArtwork artwork: Artwork) async throws -> URL
  func checkForErrorResponse(response: APIDataResponse) -> ResponseError?
  @MainActor
  func createLibrarySyncer(account: Account, storage: PersistentStorage) -> LibrarySyncer
  func createArtworkDownloadDelegate() -> DownloadManagerDelegate
  func extractArtworkInfoFromURL(urlString: String) -> ArtworkRemoteInfo?
}
