//
//  MusicPlayerTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 12.01.20.
//  Copyright (c) 2020 Maximilian Bauer. All rights reserved.
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

@testable import AmperfyKit
@preconcurrency @testable import AudioStreaming
import AVFoundation
import CoreData
import MediaPlayer
import os
import XCTest
import UIKit

// MARK: - MOCK_AudioStreamingPlayer

class MOCK_AudioStreamingPlayer: AudioStreamingPlayer {

  let starts = OSAllocatedUnfairLock(initialState: [(url: URL, volume: Float, previousState: AudioStreaming.AudioPlayerState)]())
  let pauseVolumes = OSAllocatedUnfairLock(initialState: [Float]())
  let buffering = OSAllocatedUnfairLock(initialState: false)

  nonisolated(unsafe) private var _mockElapsedTime: Double = 0.0
  private let _mockElapsedTimeLock = NSLock()
  nonisolated public var mockElapsedTime: Double {
    get {
      _mockElapsedTimeLock.withLock { _mockElapsedTime }
    }
    set {
      _mockElapsedTimeLock.withLock { _mockElapsedTime = newValue }
    }
  }

  nonisolated(unsafe) private var _isPlaying = false
  private let _isPlayingLock = NSLock()
  nonisolated public var isPlaying: Bool {
    get {
      _isPlayingLock.withLock { _isPlaying }
    }
    set {
      _isPlayingLock.withLock { _isPlaying = newValue }
    }
  }

  nonisolated(unsafe) private var _isStopped = true
  private let _isStoppedLock = NSLock()
  nonisolated public var isStopped: Bool {
    get {
      _isStoppedLock.withLock { _isStopped }
    }
    set {
      _isStoppedLock.withLock { _isStopped = newValue }
    }
  }

  override func play(url: URL) {
    let start = (url: url, volume: volume, previousState: getState())
    starts.withLock { $0.append(start) }
    mockElapsedTime = 0.0
    isPlaying = true
    isStopped = false
    // The backend delegate performs its own main-actor hop, just as for a real engine.
    delegate?.audioPlayerDidStartPlaying(player: self, with: AudioEntryId(id: url.absoluteString))
  }

  override func pause() {
    let level = volume
    pauseVolumes.withLock { $0.append(level) }
    isPlaying = false
  }

  override func resume() {
    isPlaying = true
    isStopped = false
  }

  override func stop(clearQueue: Bool = true) {
    isPlaying = false
    isStopped = true
  }

  override func queue(url: URL) {}
  override func seek(to time: Double) {
    mockElapsedTime = time
  }

  override func elapsedTime() -> Double {
    mockElapsedTime
  }

  override func getState() -> AudioStreaming.AudioPlayerState {
    if isStopped { return .stopped }
    if !isPlaying { return .paused }
    return buffering.withLock { $0 } ? .bufferring : .playing
  }
}

// MARK: - MOCK_SongDownloader

class MOCK_SongDownloader: DownloadManageable {
  var urlSessionIdentifier: String? {
    ""
  }

  var downloadables = [Downloadable]()
  func isNoDownloadRequested() -> Bool {
    downloadables.isEmpty
  }

  func getBackgroundFetchCompletionHandler() async -> AmperfyKit.CompleteHandlerBlock? { nil }
  func setBackgroundFetchCompletionHandler(_ newValue: AmperfyKit.CompleteHandlerBlock?) {}
  func download(object: Downloadable) { downloadables.append(object) }
  func download(objects: [Downloadable]) { downloadables.append(contentsOf: objects) }
  func removeFinishedDownload(for object: Downloadable) {}
  func removeFinishedDownload(for objects: [Downloadable]) {}
  func clearFinishedDownloads() {}
  func resetFailedDownloads() {}
  func cancelDownloads() {}
  func start() {}
  func stop() {}
}

// MARK: - MOCK_AlertDisplayable

class MOCK_AlertDisplayable: AlertDisplayable {
  func display(
    title: String,
    subtitle: String,
    style: LogEntryType,
    notificationBanner popupVC: UIViewController
  ) {}
  func display(popup popupVC: UIViewController) {}
  func createPopupVC(
    topic: String,
    shortMessage: String,
    detailMessage: String,
    logType: AmperfyKit.LogEntryType
  )
    -> UIViewController { UIViewController() }
}

// MARK: - MOCK_LibrarySyncer

@MainActor
final class MOCK_LibrarySyncer: LibrarySyncer {
  var submittedListens: [(id: String, date: Date?)] = []
  var submissionError: Error?
  var onScrobble: (() -> Void)?
  func syncInitial(statusNotifyier: SyncCallbacks?) async throws {}
  func sync(genre: Genre) async throws {}
  func sync(artist: Artist) async throws {}
  func sync(album: Album) async throws {}
  var syncedSongs = [String]()
  var onSyncSong: (@MainActor (Song) async throws -> Void)?
  func sync(song: Song) async throws {
    syncedSongs.append(song.uniqueID)
    try await onSyncSong?(song)
  }
  func sync(podcast: Podcast) async throws {}
  func syncNewestPodcastEpisodes() async throws {}
  func syncNewestAlbums(offset: Int, count: Int) async throws {}
  func syncRecentAlbums(offset: Int, count: Int) async throws {}
  func syncFavoriteLibraryElements() async throws {}
  func syncRadios() async throws {}
  func syncDownPlaylistsWithoutSongs() async throws {}
  func syncDown(playlist: Playlist) async throws {}
  func syncUpload(playlistToUpdateName playlist: Playlist) async throws {}
  func syncUpload(playlistToAddSongs playlist: Playlist, songs: [Song]) async throws {}
  func syncUpload(playlistToDeleteSong playlist: Playlist, index: Int) async throws {}
  func syncUpload(playlistToUpdateOrder playlist: Playlist) async throws {}
  func syncUpload(playlistIdToDelete id: String) async throws {}
  func syncDownPodcastsWithoutEpisodes() async throws {}
  func searchArtists(searchText: String) async throws {}
  func searchAlbums(searchText: String) async throws {}
  func searchSongs(searchText: String) async throws {}
  func syncMusicFolders() async throws {}
  func syncIndexes(musicFolder: MusicFolder) async throws {}
  func sync(directory: Directory) async throws {}
  func requestRandomSongs(playlist: Playlist, count: Int) async throws {}
  func requestSimilarSongs(song: Song, count: Int) async throws -> [Song] { [] }
  func requestPodcastEpisodeDelete(podcastEpisode: PodcastEpisode) async throws {}
  func syncNowPlaying(song: Song, songPosition: NowPlayingSongPosition) async throws {}
  func scrobble(song: Song, date: Date?) async throws {
    if let submissionError { throw submissionError }
    submittedListens.append((song.id, date))
    onScrobble?()
  }
  func setRating(song: Song, rating: Int) async throws {}
  func setRating(album: Album, rating: Int) async throws {}
  func setRating(artist: Artist, rating: Int) async throws {}
  func setFavorite(song: Song, isFavorite: Bool) async throws {}
  func setFavorite(album: Album, isFavorite: Bool) async throws {}
  func setFavorite(artist: Artist, isFavorite: Bool) async throws {}
  func parseLyrics(relFilePath: URL) async throws -> LyricsList { LyricsList() }
}

// MARK: - MOCK_DownloadManagerDelegate

final class MOCK_DownloadManagerDelegate: DownloadManagerDelegate {
  var requestPredicate: NSPredicate { NSPredicate(value: true) }
  let parallelDownloadsCount = 2
  let httpHeaders: [String: String] = [:]
  func prepareDownload(
    downloadInfo: AmperfyKit.DownloadElementInfo,
    storage: AmperfyKit.AsyncCoreDataAccessWrapper
  ) async throws
    -> URL {
    throw BackendError.notSupported
  }

  func validateDownloadedData(fileURL: URL?, downloadURL: URL?) -> ResponseError? { nil }
  func completedDownload(
    downloadInfo: AmperfyKit.DownloadElementInfo,
    fileURL: URL,
    fileMimeType: String?,
    storage: AmperfyKit.AsyncCoreDataAccessWrapper
  ) async {}

  func failedDownload(
    downloadInfo: AmperfyKit.DownloadElementInfo,
    storage: AmperfyKit.AsyncCoreDataAccessWrapper
  ) async {}
}

// MARK: - MOCK_BackendApi

final class MOCK_BackendApi: BackendApi {
  @MainActor var resolveStream: @MainActor @Sendable () async -> URL = { Helper.testURL }
  let clientApiVersion: String = ""
  let serverApiVersion: String = ""
  let httpHeaders: [String: String] = [:]
  func provideCredentials(credentials: LoginCredentials) {}
  func isAuthenticationValid(credentials: LoginCredentials) async throws {
    throw BackendError.notSupported
  }

  func generateUrl(
    forDownloadingPlayable playableInfo: AbstractPlayableInfo
  ) async throws
    -> URL {
    Helper.testURL
  }

  func generateUrl(
    forStreamingPlayable playableInfo: AbstractPlayableInfo,
    maxBitrate: StreamingMaxBitratePreference,
    formatPreference: StreamingFormatPreference
  ) async throws
    -> URL {
    await resolveStream()
  }

  func generateUrl(forArtwork artwork: Artwork) async throws -> URL { Helper.testURL }
  func checkForErrorResponse(response: APIDataResponse) -> ResponseError? { nil }
  func createLibrarySyncer(
    account: AmperfyKit.Account,
    storage: PersistentStorage
  )
    -> LibrarySyncer { MOCK_LibrarySyncer() }
  func createArtworkDownloadDelegate()
    -> DownloadManagerDelegate { MOCK_DownloadManagerDelegate() }
  func extractArtworkInfoFromURL(urlString: String) -> ArtworkRemoteInfo? { nil }
  func cleanse(url: URL?) -> CleansedURL { CleansedURL(urlString: "") }
}

// MARK: - MOCK_NetworkMonitor

final class MOCK_NetworkMonitor: NetworkMonitorFacade {
  var connectionTypeChangedCB: ConnectionTypeChangedCallack? { get { nil } set {} }
  nonisolated(unsafe) private var connected = true
  private let connectionLock = NSLock()
  var isConnectedToNetwork: Bool {
    get { connectionLock.withLock { connected } }
    set { connectionLock.withLock { connected = newValue } }
  }
  var isCellular: Bool { false }
  var isWifiOrEthernet: Bool { true }
}

// MARK: - MOCK_MusicPlayable

class MOCK_MusicPlayable: MusicPlayable {
  var thrownError: Error?
  var lyricsTimes: [CMTime] = []
  var elapsedTimeChangeCount = 0

  var expectationDidStartPlaying: XCTestExpectation?
  var expectationErrorOccurred: XCTestExpectation?

  func didStartPlayingFromBeginning() {}
  func didStartPlaying() {
    expectationDidStartPlaying?.fulfill()
  }

  func didPause() {}
  func didStopPlaying() {}
  func didElapsedTimeChange() { elapsedTimeChangeCount += 1 }
  func didLyricsTimeChange(time: CMTime) { lyricsTimes.append(time) }
  func didPlaylistChange() {}
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}

  func errorOccurred(_ error: Error) {
    thrownError = error
    expectationErrorOccurred?.fulfill()
  }
}

// MARK: - MOCK_CoreDataManager

class MOCK_CoreDataManager: CoreDataManagable {
  var mock_persistentContainer: NSPersistentContainer

  init(persistentContainer: NSPersistentContainer) {
    self.mock_persistentContainer = persistentContainer
  }

  var persistentContainer: NSPersistentContainer {
    mock_persistentContainer
  }

  var context: NSManagedObjectContext {
    mock_persistentContainer.viewContext
  }
}

// MARK: - MusicPlayerTest

@MainActor
class MusicPlayerTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var mockAlertDisplayer: MOCK_AlertDisplayable!
  var mockCoreDataManager: MOCK_CoreDataManager!
  var storage: PersistentStorage!
  var eventLogger: EventLogger!
  var userStatistics: UserStatistics!
  var songDownloader: MOCK_SongDownloader!
  var backendApi: MOCK_BackendApi!
  var networkMonitor: MOCK_NetworkMonitor!
  var backendPlayer: BackendAudioPlayer!
  var mockMusicPlayable: MOCK_MusicPlayable!
  var playerData: PlayerData!
  var testMusicPlayer: AmperfyKit.AudioPlayer!
  var testPlayer: AmperfyKit.PlayerFacade!
  var testQueueHandler: AmperfyKit.PlayQueueHandler!
  var mockAudioStreamingPlayer: MOCK_AudioStreamingPlayer!

  var songCached: Song!
  var songToDownload: Song!
  var playlistThreeCached: Playlist!
  var playlistAllCached: Playlist!
  let fillCount = 5
  private var savedAutoplayEnabled: Bool?

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    songDownloader = MOCK_SongDownloader()
    mockAudioStreamingPlayer = MOCK_AudioStreamingPlayer()
    mockAlertDisplayer = MOCK_AlertDisplayable()
    mockCoreDataManager = MOCK_CoreDataManager(persistentContainer: cdHelper.persistentContainer)
    storage = PersistentStorage(coreDataManager: mockCoreDataManager)
    eventLogger = EventLogger(storage: storage)
    userStatistics = library.getUserStatistics(appVersion: "")
    backendApi = MOCK_BackendApi()
    networkMonitor = MOCK_NetworkMonitor()
    backendPlayer = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { self.mockAudioStreamingPlayer },
      audioSessionHandler: AudioSessionHandler(),
      eventLogger: eventLogger,
      getBackendApiCB: { accountInfo in self.backendApi },
      networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { accountInfo in self.songDownloader },
      cacheProxy: library,
      userStatistics: userStatistics
    )
    mockMusicPlayable = MOCK_MusicPlayable()
    playerData = library.getPlayerData()
    testQueueHandler = PlayQueueHandler(playerData: playerData)
    testMusicPlayer = AudioPlayer(
      coreData: playerData,
      queueHandler: testQueueHandler,
      backendAudioPlayer: backendPlayer,
      settings: storage.settings,
      userStatistics: userStatistics
    )
    testPlayer = PlayerFacadeImpl(
      playerStatus: playerData,
      queueHandler: testQueueHandler,
      musicPlayer: testMusicPlayer,
      library: library,
      backendAudioPlayer: backendPlayer,
      userStatistics: userStatistics
    )
    testPlayer.addNotifier(notifier: mockMusicPlayable)

    guard let songCachedFetched = library.getSong(for: account, id: "36") else { XCTFail(); return }
    songCached = songCachedFetched
    guard let songToDownloadFetched = library.getSong(for: account, id: "3")
    else { XCTFail(); return }
    songToDownload = songToDownloadFetched
    guard let playlistCached = library.getPlaylist(
      for: account,
      id: cdHelper.seeder.playlists[1].id
    )
    else { XCTFail(); return }
    playlistThreeCached = playlistCached
    guard let playlistAllCachedFetched = library.getPlaylist(
      for: account,
      id: cdHelper.seeder.playlists[3].id
    )
    else { XCTFail(); return }
    playlistAllCached = playlistAllCachedFetched
  }

  override func tearDown() async throws {
    if let savedAutoplayEnabled {
      testPlayer.setAutoplayEnabled(false)
      storage.settings.user.isAutoplayEnabled = savedAutoplayEnabled
    }
    backendPlayer.stop()
    mockAudioStreamingPlayer.delegate = nil
  }

  private func startScrobbleStream() async throws {
    storage.settings.user.isOfflineMode = false
    testPlayer.isAutoCachePlayedItems = false
    songToDownload.playDuration = 100
    testPlayer.play(context: PlayContext(name: "Scrobble", playables: [songToDownload]))
    for _ in 0..<50 {
      if testPlayer.playType == .stream, testPlayer.isPlaying { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(testPlayer.playType, .stream)
    XCTAssertEqual(testPlayer.currentlyPlaying, songToDownload)
  }

  func testInactiveEqualizerBypassesIdentityBandsAndRestoresSelectedGains() {
    backendPlayer.updateEqualizerEnabled(isEnabled: true)
    backendPlayer.updateEqualizerSetting(eqSetting: .off)
    XCTAssertEqual(backendPlayer.activeEqualizerBandCount, 0)
    let custom = EqualizerSetting(name: "Two bands", gains: [2, 0, 0, -3, 0, 0, 0, 0, 0, 0])
    backendPlayer.updateEqualizerSetting(eqSetting: custom)
    XCTAssertEqual(backendPlayer.activeEqualizerBandCount, 2)
    backendPlayer.updateEqualizerEnabled(isEnabled: false)
    XCTAssertEqual(backendPlayer.activeEqualizerBandCount, 0)
    backendPlayer.updateEqualizerEnabled(isEnabled: true)
    XCTAssertEqual(backendPlayer.activeEqualizerBandCount, 2)
  }

  func testSystemProgressAnchorSkipsLinearPlaybackButDetectsSeekBufferingAndRateChanges() {
    let anchor = NowPlayingTimingAnchor(elapsed: 30, duration: 200, rate: 1, uptime: 100)
    for second in 1...120 {
      XCTAssertFalse(anchor.needsUpdate(elapsed: 30 + Double(second), duration: 200, rate: 1, uptime: 100 + Double(second)))
    }
    XCTAssertTrue(anchor.needsUpdate(elapsed: 80, duration: 200, rate: 1, uptime: 105))
    XCTAssertTrue(anchor.needsUpdate(elapsed: 30, duration: 200, rate: 0, uptime: 101))
    XCTAssertTrue(anchor.needsUpdate(elapsed: 35, duration: 200, rate: 1.5, uptime: 105))
    XCTAssertTrue(anchor.needsUpdate(elapsed: 35, duration: 220, rate: 1, uptime: 105))
  }

  func testLockScreenShortSeekAndBufferingUpdateWithoutPollingDelay() async throws {
    try await startCachedSong(at: 37)
    let center = MPNowPlayingInfoCenter.default()
    let handler = NowPlayingInfoCenterHandler(musicPlayer: testMusicPlayer, backendAudioPlayer: backendPlayer,
      nowPlayingInfoCenter: center, storage: storage, notificationHandler: EventNotificationHandler(),
      getArtworkDownloaderCB: { _ in self.songDownloader }, getPlayableDownloaderCB: { _ in self.songDownloader })
    testPlayer.addNotifier(notifier: handler)
    defer { handler.didStopPlaying() }
    handler.didStartPlaying()
    testPlayer.seek(toSecond: 37.25)
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 37.25)
    mockAudioStreamingPlayer.buffering.withLock { $0 = true }
    backendPlayer.audioPlayerStateChanged(player: mockAudioStreamingPlayer, with: .bufferring, previous: .playing)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
    mockAudioStreamingPlayer.buffering.withLock { $0 = false }
    backendPlayer.audioPlayerStateChanged(player: mockAudioStreamingPlayer, with: .playing, previous: .bufferring)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
  }

  func testBackgroundStopsLyricsButKeepsPlaybackAndProgress() async throws {
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await startScrobbleStream()
    for _ in 0..<100 {
      if !mockMusicPlayable.lyricsTimes.isEmpty { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(mockMusicPlayable.lyricsTimes.isEmpty)

    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    let backgroundLyricsCount = mockMusicPlayable.lyricsTimes.count
    let progressCount = mockMusicPlayable.elapsedTimeChangeCount
    mockAudioStreamingPlayer.mockElapsedTime = 21
    XCTAssertEqual(backendPlayer.elapsedUpdateInterval, 5)
    try await Task.sleep(for: .milliseconds(1250))
    XCTAssertEqual(mockMusicPlayable.elapsedTimeChangeCount, progressCount,
                   "Hidden playback must not keep the foreground 1Hz bookkeeping timer")
    for _ in 0..<275 {
      if mockMusicPlayable.elapsedTimeChangeCount > progressCount { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(mockMusicPlayable.lyricsTimes.count, backgroundLyricsCount)
    XCTAssertGreaterThan(mockMusicPlayable.elapsedTimeChangeCount, progressCount)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertTrue(mockAudioStreamingPlayer.isPlaying)
    XCTAssertFalse(backendPlayer.audioAnalyzer.isInForeground)

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(mockMusicPlayable.lyricsTimes.last?.seconds, 21)
    let foregroundLyricsCount = mockMusicPlayable.lyricsTimes.count
    for _ in 0..<100 {
      if mockMusicPlayable.lyricsTimes.count > foregroundLyricsCount { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertGreaterThan(mockMusicPlayable.lyricsTimes.count, foregroundLyricsCount)
    XCTAssertTrue(backendPlayer.audioAnalyzer.isInForeground)

    testPlayer.pause()
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    let pausedLyricsCount = mockMusicPlayable.lyricsTimes.count
    try await Task.sleep(for: .milliseconds(250))
    XCTAssertEqual(mockMusicPlayable.lyricsTimes.count, pausedLyricsCount)
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testBackgroundDropsQueuedVisualizerUpdateAndForegroundResumes() async throws {
    let analyzer = backendPlayer.audioAnalyzer
    backendPlayer.setVisualUpdatesEnabled(true)
    analyzer.isActive = true
    analyzer.playing(sampleRate: 16_000)
    analyzer.play()
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
    buffer.frameLength = 256
    let data = try XCTUnwrap(buffer.floatChannelData).pointee
    for index in 0..<256 { data[index] = 0.5 }
    let time = AVAudioTime(sampleTime: 0, atRate: 16_000)

    XCTAssertTrue(analyzer.isTapInstalled)
    analyzer.calculate(buffer: buffer, audioTime: time)
    backendPlayer.setVisualUpdatesEnabled(false)
    XCTAssertFalse(analyzer.isTapInstalled, "Background playback must not copy visualization samples")
    await Task.yield()
    XCTAssertEqual(analyzer.rms, 0, "A queued foreground result must not publish in the background")
    analyzer.calculate(buffer: buffer, audioTime: time)
    await Task.yield()
    XCTAssertEqual(analyzer.rms, 0)
    XCTAssertTrue(analyzer.isActive, "Backgrounding must preserve the selected visualizer")

    backendPlayer.setVisualUpdatesEnabled(true)
    XCTAssertTrue(analyzer.isTapInstalled)
    analyzer.calculate(buffer: buffer, audioTime: time)
    for _ in 0..<10 {
      if analyzer.rms > 0 { break }
      await Task.yield()
    }
    XCTAssertGreaterThan(analyzer.rms, 0)
  }

  func testStreamScrobbleSubmitsAtThresholdOnlyOnceAcrossPauseAndResume() async throws {
    try await startScrobbleStream()
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = true }
    let api = MOCK_LibrarySyncer()
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    let started = clock
    let scrobbler = ScrobbleSyncer(player: testPlayer, networkMonitor: networkMonitor,
      account: account, storage: storage, librarySyncer: api, eventLogger: eventLogger, now: { clock })
    scrobbler.didStartPlayingFromBeginning()
    scrobbler.didStartPlaying()
    let submitted = expectation(description: "Stream submitted without pausing or changing tracks")
    api.onScrobble = { submitted.fulfill() }
    clock = clock.addingTimeInterval(50)
    scrobbler.didElapsedTimeChange()
    await fulfillment(of: [submitted], timeout: 3)
    api.onScrobble = nil
    XCTAssertEqual(api.submittedListens.first?.id, songToDownload.id)
    XCTAssertEqual(api.submittedListens.first?.date, started)
    scrobbler.didPause()
    clock = clock.addingTimeInterval(100)
    scrobbler.didStartPlaying()
    scrobbler.didElapsedTimeChange()
    scrobbler.didStopPlaying()
    XCTAssertEqual(library.getScrobbleEntries(for: account).count, 1)
    XCTAssertEqual(api.submittedListens.count, 1)
  }

  func testScrobbleCountsListeningTimeInsteadOfSeekPositionOrPauseTime() async throws {
    try await startScrobbleStream()
    networkMonitor.isConnectedToNetwork = false
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = true }
    var clock = Date()
    let scrobbler = ScrobbleSyncer(player: testPlayer, networkMonitor: networkMonitor,
      account: account, storage: storage, librarySyncer: MOCK_LibrarySyncer(), eventLogger: eventLogger, now: { clock })
    scrobbler.didStartPlayingFromBeginning()
    clock = clock.addingTimeInterval(20)
    mockAudioStreamingPlayer.mockElapsedTime = 99
    scrobbler.didElapsedTimeChange()
    scrobbler.didPause()
    clock = clock.addingTimeInterval(500)
    scrobbler.didElapsedTimeChange()
    XCTAssertTrue(library.getScrobbleEntries(for: account).isEmpty)
    scrobbler.didStartPlaying()
    clock = clock.addingTimeInterval(29)
    scrobbler.didElapsedTimeChange()
    XCTAssertTrue(library.getScrobbleEntries(for: account).isEmpty)
    clock = clock.addingTimeInterval(1)
    scrobbler.didElapsedTimeChange()
    XCTAssertEqual(library.getUploadableScrobbleEntryCount(for: account), 1)
    scrobbler.didStopPlaying()
  }

  func testOfflineScrobbleRetriesWithOriginalPlayTimestamp() async throws {
    try await startScrobbleStream()
    networkMonitor.isConnectedToNetwork = false
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = true }
    let api = MOCK_LibrarySyncer()
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    let started = clock
    let scrobbler = ScrobbleSyncer(player: testPlayer, networkMonitor: networkMonitor,
      account: account, storage: storage, librarySyncer: api, eventLogger: eventLogger, now: { clock })
    scrobbler.didStartPlayingFromBeginning()
    clock = clock.addingTimeInterval(50)
    scrobbler.didElapsedTimeChange()
    scrobbler.didStopPlaying()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(library.getUploadableScrobbleEntryCount(for: account), 1)
    XCTAssertTrue(api.submittedListens.isEmpty)
    let submitted = expectation(description: "Offline listen uploaded")
    api.onScrobble = { submitted.fulfill() }
    networkMonitor.isConnectedToNetwork = true
    scrobbler.start()
    await fulfillment(of: [submitted], timeout: 3)
    XCTAssertEqual(api.submittedListens.first?.date, started)
    XCTAssertEqual(library.getUploadableScrobbleEntryCount(for: account), 0)
  }

  func testPreparedButPausedSongDoesNotCreateAListen() async throws {
    try await startScrobbleStream()
    testPlayer.pause()
    var clock = Date()
    let scrobbler = ScrobbleSyncer(player: testPlayer, networkMonitor: networkMonitor,
      account: account, storage: storage, librarySyncer: MOCK_LibrarySyncer(), eventLogger: eventLogger, now: { clock })
    scrobbler.didStartPlayingFromBeginning()
    scrobbler.didStartPlaying()
    clock = clock.addingTimeInterval(300)
    scrobbler.didElapsedTimeChange()
    scrobbler.didStopPlaying()
    XCTAssertTrue(library.getScrobbleEntries(for: account).isEmpty)
  }

  func testExplicitlyDisabledStreamingScrobblesStayDisabled() async throws {
    try await startScrobbleStream()
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = false }
    var clock = Date()
    let scrobbler = ScrobbleSyncer(player: testPlayer, networkMonitor: networkMonitor,
      account: account, storage: storage, librarySyncer: MOCK_LibrarySyncer(), eventLogger: eventLogger, now: { clock })
    scrobbler.didStartPlayingFromBeginning()
    clock = clock.addingTimeInterval(100)
    scrobbler.didElapsedTimeChange()
    scrobbler.didPause()
    scrobbler.didStartPlaying()
    scrobbler.didStopPlaying()
    XCTAssertTrue(library.getScrobbleEntries(for: account).isEmpty)
  }

  func testStreamingScrobbleDefaultAppliesOnce() {
    let key = "player.scrobbleStreams.v1"
    let original = UserDefaults.standard.object(forKey: key)
    defer {
      if let original { UserDefaults.standard.set(original, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    UserDefaults.standard.removeObject(forKey: key)
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = false }
    storage.settings.applyStreamingScrobbleDefaultIfNeeded()
    XCTAssertTrue(storage.settings.accounts.getSetting(account.info).read.isScrobbleStreamedItems)
    XCTAssertTrue(AccountSetting().isScrobbleStreamedItems)
    storage.settings.accounts.updateSetting(account.info) { $0.isScrobbleStreamedItems = false }
    storage.settings.applyStreamingScrobbleDefaultIfNeeded()
    XCTAssertFalse(storage.settings.accounts.getSetting(account.info).read.isScrobbleStreamedItems)
  }

  func testOrangeLibraryDefaultsApplyOnceAndPreserveLaterCustomization() {
    let marker = "playerAppearance.orangeSixLibraryItems.v1"
    let oldMarker = UserDefaults.standard.object(forKey: marker)
    let oldAccounts = storage.settings.accounts
    defer {
      storage.settings.accounts = oldAccounts
      if let oldMarker { UserDefaults.standard.set(oldMarker, forKey: marker) }
      else { UserDefaults.standard.removeObject(forKey: marker) }
    }
    UserDefaults.standard.removeObject(forKey: marker)
    storage.settings.accounts.updateSetting(account.info) {
      $0.themePreference = .blue
      $0.libraryDisplaySettings = LibraryDisplaySettings(inUse: [.artists, .radios])
    }
    storage.settings.applyPlayerAppearanceDefaultsIfNeeded()
    var migrated = storage.settings.accounts.getSetting(account.info).read
    XCTAssertEqual(migrated.themePreference, .orange)
    XCTAssertEqual(migrated.libraryDisplaySettings.inUse, [.artists, .albums, .songs, .favoriteSongs, .playlists, .downloads])
    XCTAssertEqual(AccountSetting().themePreference, .orange)
    XCTAssertEqual(AccountSetting().libraryDisplaySettings.inUse, migrated.libraryDisplaySettings.inUse)
    storage.settings.accounts.updateSetting(account.info) {
      $0.themePreference = .green
      $0.libraryDisplaySettings = LibraryDisplaySettings(inUse: [.songs, .playlists])
    }
    storage.settings.applyPlayerAppearanceDefaultsIfNeeded()
    migrated = storage.settings.accounts.getSetting(account.info).read
    XCTAssertEqual(migrated.themePreference, .green)
    XCTAssertEqual(migrated.libraryDisplaySettings.inUse, [.songs, .playlists])
  }

  private func makePreparationHandler(
    notifications: EventNotificationHandler = EventNotificationHandler(),
    audio: MOCK_SongDownloader, artwork: MOCK_SongDownloader, syncer: MOCK_LibrarySyncer
  ) -> PlayerDownloadPreparationHandler {
    PlayerDownloadPreparationHandler(playerStatus: playerData, musicPlayer: testMusicPlayer,
      storage: storage, notificationHandler: notifications,
      getPlayableDownloaderCB: { _ in audio }, getArtworkDownloaderCB: { _ in artwork },
      getLibrarySyncerCB: { _ in syncer })
  }

  private func writeTestCover(for song: Song, size: CGSize) throws -> URL {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    let relative = URL(string: "preload-cover-\(UUID().uuidString).png")!
    let path = try XCTUnwrap(CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relative))
    try CacheFileManager.shared.writeDataExcludedFromBackup(
      data: XCTUnwrap(image.pngData()), to: path, accountInfo: account.info)
    let artwork = library.createArtwork(account: account)
    artwork.id = UUID().uuidString
    artwork.relFilePath = relative
    artwork.status = .CustomImage
    song.artwork = artwork
    library.saveContext()
    return path
  }

  func testUpcomingPreparationFollowsQueueEditsAndRespectsCachePolicies() async throws {
    try await startAutoplayFixture()
    testPlayer.isAutoCachePlayedItems = true
    let audio = MOCK_SongDownloader(), covers = MOCK_SongDownloader(), syncer = MOCK_LibrarySyncer()
    let preparation = makePreparationHandler(audio: audio, artwork: covers, syncer: syncer)
    testPlayer.addNotifier(notifier: preparation)
    defer { preparation.didStopPlaying() }
    let artwork = library.createArtwork(account: account)
    artwork.status = .NotChecked
    songToDownload.artwork = artwork
    testPlayer.appendContextQueue(playables: [songToDownload, songCached])
    XCTAssertTrue(audio.downloadables.contains { $0.uniqueID == songToDownload.uniqueID })
    XCTAssertFalse(audio.downloadables.contains { $0.uniqueID == songCached.uniqueID })
    XCTAssertTrue(covers.downloadables.contains { $0.uniqueID == artwork.uniqueID })
    let inserted = try XCTUnwrap(playlistAllCached.playables.first { $0 != songCached })
    testPlayer.insertUserQueue(playables: [inserted])
    XCTAssertEqual(testMusicPlayer.upcomingPlayablesForPreparation(limit: 1).first, inserted)

    audio.downloadables.removeAll()
    testPlayer.isAutoCachePlayedItems = false
    preparation.didStartPlaying()
    XCTAssertTrue(audio.downloadables.isEmpty)
    covers.downloadables.removeAll()
    testPlayer.isOfflineMode = true
    preparation.didPlaylistChange()
    XCTAssertTrue(audio.downloadables.isEmpty)
    XCTAssertTrue(covers.downloadables.isEmpty)
  }

  func testGoingOfflineCancelsUpcomingMetadataBeforeItStarts() async throws {
    try await startAutoplayFixture()
    songToDownload.artwork = nil
    let audio = MOCK_SongDownloader(), covers = MOCK_SongDownloader(), syncer = MOCK_LibrarySyncer()
    let preparation = makePreparationHandler(audio: audio, artwork: covers, syncer: syncer)
    testPlayer.addNotifier(notifier: preparation)
    defer { preparation.didStopPlaying() }
    let unexpectedSync = expectation(description: "no speculative metadata request while offline")
    unexpectedSync.isInverted = true
    syncer.onSyncSong = { _ in unexpectedSync.fulfill() }

    testPlayer.appendContextQueue(playables: [songToDownload])
    testPlayer.isOfflineMode = true
    await fulfillment(of: [unexpectedSync], timeout: 0.1)
    XCTAssertTrue(syncer.syncedSongs.isEmpty)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testStoppingCancelsUpcomingMetadataBeforeItStarts() async throws {
    try await startAutoplayFixture()
    songToDownload.artwork = nil
    let audio = MOCK_SongDownloader(), covers = MOCK_SongDownloader(), syncer = MOCK_LibrarySyncer()
    let preparation = makePreparationHandler(audio: audio, artwork: covers, syncer: syncer)
    testPlayer.addNotifier(notifier: preparation)
    defer { preparation.didStopPlaying() }
    let unexpectedSync = expectation(description: "no speculative metadata request after stopping")
    unexpectedSync.isInverted = true
    syncer.onSyncSong = { _ in unexpectedSync.fulfill() }

    testPlayer.appendContextQueue(playables: [songToDownload])
    testPlayer.stop()
    await fulfillment(of: [unexpectedSync], timeout: 0.1)
    XCTAssertTrue(syncer.syncedSongs.isEmpty)
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testUpcomingMetadataAndDownloadedCoverArePreparedBeforeNextTrack() async throws {
    try await startAutoplayFixture()
    storage.settings.accounts.updateSetting(account.info) { $0.artworkDisplayPreference = .serverArtworkOnly }
    songToDownload.artwork = nil
    let audio = MOCK_SongDownloader(), covers = MOCK_SongDownloader(), syncer = MOCK_LibrarySyncer()
    let notifications = EventNotificationHandler()
    let preparation = makePreparationHandler(notifications: notifications, audio: audio, artwork: covers, syncer: syncer)
    testPlayer.addNotifier(notifier: preparation)
    defer { preparation.didStopPlaying() }
    let artwork = library.createArtwork(account: account)
    artwork.status = .NotChecked
    let synced = expectation(description: "next song metadata fetched once")
    syncer.onSyncSong = { song in song.artwork = artwork; synced.fulfill() }
    testPlayer.appendContextQueue(playables: [songToDownload])
    preparation.didShuffleChange()
    preparation.didStartPlaying()
    await fulfillment(of: [synced], timeout: 2)
    for _ in 0..<50 {
      if covers.downloadables.contains(where: { $0.uniqueID == artwork.uniqueID }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(syncer.syncedSongs, [songToDownload.uniqueID])
    XCTAssertTrue(covers.downloadables.contains { $0.uniqueID == artwork.uniqueID })
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)

    let path = try writeTestCover(for: songToDownload, size: CGSize(width: 321, height: 123))
    defer { try? CacheFileManager.shared.removeItem(at: path, accountInfo: account.info) }
    XCTAssertNil(LibraryEntityImage.preparedImage(at: path.path))
    notifications.post(name: .downloadFinishedSuccess, object: covers,
      userInfo: DownloadNotification(id: songToDownload.artwork!.uniqueID).asNotificationUserInfo)
    for _ in 0..<100 {
      if LibraryEntityImage.preparedImage(at: path.path) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(LibraryEntityImage.preparedImage(at: path.path))
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    let center = MPNowPlayingInfoCenter.default()
    let handler = NowPlayingInfoCenterHandler(musicPlayer: testMusicPlayer, backendAudioPlayer: backendPlayer,
      nowPlayingInfoCenter: center, storage: storage, notificationHandler: notifications,
      getArtworkDownloaderCB: { _ in covers }, getPlayableDownloaderCB: { _ in audio })
    defer { handler.didStopPlaying() }
    testPlayer.playNext()
    handler.didStartPlaying()
    XCTAssertEqual((center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size,
                   CGSize(width: 321, height: 123))
    XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, songToDownload.title)
  }

  func testUpcomingMissingTitleIsFetchedDespiteDisplayFallback() async throws {
    try await startAutoplayFixture()
    let next = songToDownload!
    XCTAssertNotNil(next.artist)
    XCTAssertNotNil(next.album)
    next.artwork = library.createArtwork(account: account)
    next.playableManagedObject.title = nil
    XCTAssertFalse(next.title.isEmpty) // The UI getter returns a localized fallback.
    let audio = MOCK_SongDownloader(), covers = MOCK_SongDownloader(), syncer = MOCK_LibrarySyncer()
    let preparation = makePreparationHandler(audio: audio, artwork: covers, syncer: syncer)
    testPlayer.addNotifier(notifier: preparation)
    defer { preparation.didStopPlaying() }
    let synced = expectation(description: "missing stored title fetched")
    syncer.onSyncSong = { song in
      song.title = "Prepared next track"
      synced.fulfill()
    }
    testPlayer.appendContextQueue(playables: [next])
    await fulfillment(of: [synced], timeout: 2)
    XCTAssertEqual(next.title, "Prepared next track")
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testColdDiskCoverPublishesAtomicallyAndCancelledDecodeCannotResurrectInfo() async throws {
    try await startAutoplayFixture()
    storage.settings.accounts.updateSetting(account.info) { $0.artworkDisplayPreference = .serverArtworkOnly }
    let path = try writeTestCover(for: songCached, size: CGSize(width: 317, height: 173))
    defer { try? CacheFileManager.shared.removeItem(at: path, accountInfo: account.info) }
    let center = MPNowPlayingInfoCenter.default()
    let handler = NowPlayingInfoCenterHandler(musicPlayer: testMusicPlayer, backendAudioPlayer: backendPlayer,
      nowPlayingInfoCenter: center, storage: storage, notificationHandler: EventNotificationHandler(),
      getArtworkDownloaderCB: { _ in self.songDownloader }, getPlayableDownloaderCB: { _ in self.songDownloader })
    defer { handler.didStopPlaying() }
    handler.didStopPlaying()
    XCTAssertNil(LibraryEntityImage.preparedImage(at: path.path))
    handler.didStartPlaying()
    handler.didElapsedTimeChange()
    // No default artwork is ever published while a known real disk cover decodes.
    XCTAssertNil(center.nowPlayingInfo)
    mockAudioStreamingPlayer.mockElapsedTime = 51
    for _ in 0..<100 {
      if center.nowPlayingInfo != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual((center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size,
                   CGSize(width: 317, height: 173))
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 51)

    let secondPath = try writeTestCover(for: songCached, size: CGSize(width: 201, height: 101))
    defer { try? CacheFileManager.shared.removeItem(at: secondPath, accountInfo: account.info) }
    handler.didArtworkChange()
    handler.didStopPlaying()
    for _ in 0..<100 {
      if LibraryEntityImage.preparedImage(at: secondPath.path) != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertNotNil(LibraryEntityImage.preparedImage(at: secondPath.path))
    XCTAssertNil(center.nowPlayingInfo)
  }

  func testLateLockScreenArtworkLoadsWithoutAnyPlayerViewAndSurvivesTimingUpdates() async throws {
    storage.settings.accounts.updateSetting(account.info) { $0.artworkDisplayPreference = .serverArtworkOnly }
    let artwork = library.createArtwork(account: account)
    artwork.id = "late-lock-screen"
    artwork.status = .NotChecked
    songCached.artwork = artwork
    library.saveContext()
    let notifications = EventNotificationHandler()
    let center = MPNowPlayingInfoCenter.default()
    let handler = NowPlayingInfoCenterHandler(
      musicPlayer: testMusicPlayer, backendAudioPlayer: backendPlayer,
      nowPlayingInfoCenter: center, storage: storage, notificationHandler: notifications,
      getArtworkDownloaderCB: { _ in self.songDownloader },
      getPlayableDownloaderCB: { _ in self.songDownloader }
    )
    defer { handler.didStopPlaying() }
    try await startCachedSong(at: 37)
    handler.didStartPlaying()
    let placeholder = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 312, height: 156), format: format).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 312, height: 156))
    }
    let relative = URL(string: "late-artwork-\(UUID().uuidString).png")!
    let path = try XCTUnwrap(CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relative))
    defer { try? CacheFileManager.shared.removeItem(at: path, accountInfo: account.info) }
    try CacheFileManager.shared.writeDataExcludedFromBackup(
      data: XCTUnwrap(image.pngData()), to: path, accountInfo: account.info
    )
    artwork.relFilePath = relative
    artwork.status = .CustomImage
    library.saveContext()
    notifications.post(name: .downloadFinishedSuccess, object: songDownloader,
                       userInfo: DownloadNotification(id: artwork.uniqueID).asNotificationUserInfo)
    var loaded: MPMediaItemArtwork?
    for _ in 0..<100 {
      loaded = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
      if loaded?.bounds.size == image.size { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(loaded?.bounds.size, image.size)
    XCTAssertFalse(loaded === placeholder)
    mockAudioStreamingPlayer.mockElapsedTime = 64
    handler.didElapsedTimeChange()
    XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 64)
    XCTAssertTrue((center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork) === loaded)
    handler.didPause()
    XCTAssertEqual((center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)?.bounds.size, image.size)

    // A decode completing after stop must never resurrect the lock-screen item.
    handler.didStopPlaying()
    handler.didStartPlaying()
    handler.didStopPlaying()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(center.nowPlayingInfo)
  }

  func testCurrentCoverPromotesAnExistingDownloadWithoutDuplicates() async throws {
    storage.settings.user.isOfflineMode = false
    let asyncStorage = AsyncCoreDataAccessWrapper(persistentContainer: cdHelper.persistentContainer)
    let requests = DownloadRequestManager(accountObjectId: account.managedObject.objectID, storage: asyncStorage,
                                         getDownloadDelegateCB: { MOCK_DownloadManagerDelegate() })
    let manager = DownloadManager(name: "Priority test", storage: asyncStorage, requestManager: requests,
      getDownloadDelegateCB: { MOCK_DownloadManagerDelegate() }, eventLogger: eventLogger,
      settings: storage.settings, networkMonitor: networkMonitor, notificationHandler: EventNotificationHandler(),
      urlCleanser: backendApi, limitCacheSize: false, isFailWithPopupError: false)
    let queue = await manager.taskQueue
    queue.isSuspended = true
    let session = URLSession(configuration: .ephemeral)
    defer { manager.stop(); queue.cancelAllOperations(); session.invalidateAndCancel() }
    manager.initialize(urlSession: session, isCheckForCachedNeeded: true, validationCB: nil)
    let first = library.createArtwork(account: account)
    let current = library.createArtwork(account: account)
    first.status = .NotChecked
    current.status = .NotChecked
    library.saveContext()
    let firstRequest = await requests.add(downloadInfo: try XCTUnwrap(first.threadSafeInfo))
    let currentRequest = await requests.add(downloadInfo: try XCTUnwrap(current.threadSafeInfo))
    let firstDownload = try XCTUnwrap(firstRequest)
    let currentDownload = try XCTUnwrap(currentRequest)
    await manager._start()
    manager.downloadWithPriority(object: current)
    manager.downloadWithPriority(object: current)
    for _ in 0..<100 {
      if await manager.networkPriority(for: currentDownload) == URLSessionTask.highPriority { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    // Allow both deduplicated requests to traverse the storage check.
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(queue.operationCount, 2)
    XCTAssertEqual(queue.operations.filter { $0.queuePriority == .veryHigh }.count, 1)
    XCTAssertEqual(queue.maxConcurrentOperationCount, 3)
    let currentPriority = await manager.networkPriority(for: currentDownload)
    let otherPriority = await manager.networkPriority(for: firstDownload)
    XCTAssertEqual(currentPriority, URLSessionTask.highPriority)
    XCTAssertEqual(otherPriority, URLSessionTask.defaultPriority)
    await manager.finishDownload(downloadRequest: currentDownload, task: nil, error: .alreadyDownloaded)
    XCTAssertEqual(queue.maxConcurrentOperationCount, 2)
  }

  private func startCachedSong(at time: Double) async throws {
    testPlayer.play(context: PlayContext(name: "Recovery", playables: [songCached]))
    let url = try XCTUnwrap(library.getFileURL(forPlayable: songCached))
    backendPlayer.didStartPlaying(url: url.absoluteString)
    mockAudioStreamingPlayer.mockElapsedTime = time
    for _ in 0..<5 { await Task.yield() }
  }

  func testCancelPendingQueuePreservesCurrentStreamAndPosition() async throws {
    try await startCachedSong(at: 87.25)
    testPlayer.pause()
    let count = songCached.playCount
    backendPlayer.audioPlayerDidCancel(player: mockAudioStreamingPlayer,
      queuedItems: [AudioEntryId(id: "cancelled-next-song")])
    for _ in 0..<5 { await Task.yield() }
    XCTAssertTrue(backendPlayer.canBeContinued)
    testPlayer.play()
    XCTAssertEqual(testPlayer.elapsedTime, 87.25, accuracy: 0.01)
    XCTAssertEqual(songCached.playCount, count)
  }

  func testRapidManualSkipsReplaceOnlyTheLastSourceAtZeroVolume() async throws {
    let songs = Array(playlistAllCached.playables.prefix(3))
    for (index, song) in songs.enumerated() {
      markAsCached(playable: song, cacheName: "skip-\(index)")
    }
    let urls = try songs.map { try XCTUnwrap(library.getFileURL(forPlayable: $0)) }
    songs[0].replayGainTrackGain = -12
    songs[2].replayGainTrackGain = 0
    backendPlayer.updateEqualizerEnabled(isEnabled: false)
    backendPlayer.updateReplayGainEnabled(isEnabled: true)
    let replayGain = try XCTUnwrap(mockAudioStreamingPlayer.customAttachedNodes.compactMap { $0 as? AVAudioMixerNode }.first)
    testPlayer.volume = 0.7
    testPlayer.play(context: PlayContext(name: "Skips", playables: songs))
    for _ in 0..<100 {
      if mockAudioStreamingPlayer.volume >= 0.699 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 0.7, accuracy: 0.001)
    // Starting a new context pauses the previous context even when it is empty.
    // Count only hardware pauses caused by the two manual skips below.
    mockAudioStreamingPlayer.pauseVolumes.withLock { $0.removeAll() }
    testPlayer.playNext()
    testPlayer.playNext()
    XCTAssertEqual(replayGain.outputVolume, 0.251, accuracy: 0.002, "Outgoing audio must keep its own gain")
    testPlayer.volume = 0.4
    for _ in 0..<200 {
      if mockAudioStreamingPlayer.starts.withLock({ $0.last?.url }) == urls[2],
         abs(mockAudioStreamingPlayer.volume - 0.4) < 0.001 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let starts = mockAudioStreamingPlayer.starts.withLock { $0 }
    XCTAssertEqual(starts.map { $0.url }, [urls[0], urls[2]])
    XCTAssertEqual(starts.last?.volume, 0)
    XCTAssertEqual(starts.last?.previousState, .paused, "Decoder replacement must run with the outgoing hardware paused")
    XCTAssertEqual(mockAudioStreamingPlayer.pauseVolumes.withLock { $0 }, [0], "Only the winning skip should pause, at silence")
    XCTAssertEqual(replayGain.outputVolume, 1, accuracy: 0.001)
    XCTAssertEqual(testPlayer.volume, 0.4, accuracy: 0.001)
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 0.4, accuracy: 0.001)
  }

  func testOfflineEngineRendersContinuousSamplesAtPauseAndSourceChange() throws {
    let engine = AVAudioEngine()
    let source = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 1)
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    engine.attach(source)
    engine.attach(eq)
    engine.connect(source, to: eq, format: format)
    engine.connect(eq, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let gate = try XCTUnwrap(QMPlaybackEnvelope(node: eq))
    try engine.start()
    defer { engine.stop() }

    func playSignal(_ amplitude: Float) throws {
      let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
      buffer.frameLength = buffer.frameCapacity
      for channel in 0..<2 {
        let samples = try XCTUnwrap(buffer.floatChannelData)[channel]
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = channel == 0 ? amplitude : -amplitude }
      }
      source.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
      source.play()
    }
    func render() throws -> [[Float]] {
      var result = [[Float](), [Float]()]
      for size: AVAudioFrameCount in [127, 512, 257, 1024, 1024] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size))
        let status = try engine.renderOffline(size, to: buffer)
        XCTAssertEqual(status, .success)
        XCTAssertEqual(buffer.frameLength, size)
        for channel in 0..<2 {
          result[channel].append(contentsOf: UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData)[channel],
                                                                  count: Int(buffer.frameLength)))
        }
      }
      return result
    }

    try playSignal(0.75)
    let muted = try render()
    gate.isOpen = true
    let fadeIn = try render()
    gate.isOpen = false
    let fadeOut = try render()
    XCTAssertTrue(gate.hasRenderedSilence)
    source.stop()
    try playSignal(-0.75)
    let handoff = try render()
    gate.isOpen = true
    let replacement = try render()
    for channel in 0..<2 {
      XCTAssertTrue(muted[channel].allSatisfy { $0 == 0 })
      XCTAssertTrue(handoff[channel].allSatisfy { $0 == 0 })
      let peak = try XCTUnwrap(fadeIn[channel].last)
      XCTAssertGreaterThan(abs(peak), 0.2)
      XCTAssertEqual(fadeOut[channel].last, 0)
      XCTAssertEqual(try XCTUnwrap(replacement[channel].last), -peak, accuracy: 0.001)
      let samples = muted[channel] + fadeIn[channel] + fadeOut[channel] + handoff[channel] + replacement[channel]
      let largestJump = zip(samples, samples.dropFirst()).map { abs($0.0 - $0.1) }.max() ?? 1
      XCTAssertLessThan(largestJump, abs(peak) * 0.003, "Discontinuity in rendered PCM on channel \(channel)")
    }
  }

  func testLiveDecoderHandoffBetweenAudibleFiles() async throws {
    // Catch a blocked hardware/decoder handoff without exhausting the CI job.
    executionTimeAllowance = 60
    let engine = AudioStreamingPlayer()
    let backend = BackendAudioPlayer(
      createAudioStreamingPlayerCB: { engine }, audioSessionHandler: AudioSessionHandler(),
      eventLogger: eventLogger, getBackendApiCB: { _ in self.backendApi }, networkMonitor: networkMonitor,
      getPlayableDownloaderCB: { _ in self.songDownloader }, cacheProxy: library,
      userStatistics: userStatistics, visualUpdatesEnabled: false
    )
    let songs = Array(playlistAllCached.playables.prefix(2))
    var files = [URL]()
    defer {
      for file in files { try? CacheFileManager.shared.removeItem(at: file, accountInfo: account.info) }
    }
    // Constant, opposite-sign samples make a truncated tail or a leaked old
    // buffer measurable. Exercise a decoder format change on the live player.
    for (index, song) in songs.enumerated() {
      let path = URL(string: "handoff-\(UUID().uuidString).wav")!
      let url = try XCTUnwrap(CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: path))
      files.append(url)
      let rate: Double = index == 0 ? 44100 : 48000
      let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
      let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
      ])
      let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
      pcm.frameLength = pcm.frameCapacity
      let channels = try XCTUnwrap(pcm.floatChannelData)
      for ch in 0..<2 {
        for frame in 0..<Int(pcm.frameLength) { channels[ch][frame] = index == 0 ? 0.4 : -0.3 }
      }
      for _ in 0..<6 { try file.write(from: pcm) }
      song.relFilePath = path
    }
    let samples = OSAllocatedUnfairLock(initialState: [Float]())
    // Observe the exact buffers supplied to the output unit. An AVAudioNode tap
    // batches samples asynchronously and loses its pending tail on engine.reset(),
    // which can make a correctly rendered fade look like a discontinuity.
    let output = engine.player.auAudioUnit
    // Core Audio already invokes this immutable provider on its render thread,
    // but the imported block type does not declare Sendable.
    nonisolated(unsafe) let render = try XCTUnwrap(output.outputProvider)
    XCTAssertEqual(output.inputBusses[0].format.commonFormat, .pcmFormatFloat32)
    output.outputProvider = { @Sendable flags, time, frames, bus, data in
      let status = render(flags, time, frames, bus, data)
      guard status == noErr, bus == 0, frames > 0 else { return status }
      let buffer = data.pointee.mBuffers
      guard let pointer = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0,
            Int(buffer.mDataByteSize) >= Int(frames * buffer.mNumberChannels) * MemoryLayout<Float>.size
      else { return status }
      let stride = Int(buffer.mNumberChannels)
      let silent = flags.pointee.contains(.unitRenderAction_OutputIsSilence)
      let chunk = (0..<Int(frames)).map { silent ? Float.zero : pointer[$0 * stride] }
      samples.withLock { $0.append(contentsOf: chunk) }
      return status
    }
    defer {
      backend.stop()
      output.outputProvider = render
    }
    func playAndWait(for index: Int) async throws {
      backend.requestToPlay(playable: songs[index], playbackRate: .one, autoStartPlayback: true)
      for _ in 0..<400 {
        if let last = samples.withLock({ $0.last }), index == 0 ? last > 0.2 : last < -0.15 { return }
        try await Task.sleep(for: .milliseconds(20))
      }
      XCTFail("Live output never reached file \(index)")
    }
    try await playAndWait(for: 0)
    let boundary = samples.withLock { $0.count - 1 }
    try await playAndWait(for: 1)
    let handoff = samples.withLock { Array($0.dropFirst(max(0, boundary))) }
    XCTAssertGreaterThan(handoff.first ?? 0, 0.2)
    XCTAssertLessThan(handoff.last ?? 0, -0.15)
    XCTAssertTrue(handoff.contains(0), "No silence between decoded files")
    let jumps = zip(handoff, handoff.dropFirst()).map { abs($0.0 - $0.1) }
    let worst = jumps.indices.max { jumps[$0] < jumps[$1] } ?? 0
    let context = Array(handoff.dropFirst(max(0, worst - 4)).prefix(10))
    XCTAssertLessThan(jumps.max() ?? 1, 0.02,
                      "Abrupt step in hardware output at frame \(worst): \(context)")
  }

  func testRapidResumeCancelsPendingHardwarePause() async throws {
    try await startCachedSong(at: 12)
    for _ in 0..<100 {
      if mockAudioStreamingPlayer.volume >= 0.999 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    testPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertTrue(mockAudioStreamingPlayer.isPlaying, "The renderer needs to deliver its fade before hardware pauses")
    testPlayer.play()
    try await Task.sleep(for: .milliseconds(650))
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertTrue(mockAudioStreamingPlayer.isPlaying)
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 1, accuracy: 0.001)
  }

  func testReplacementStaysMutedThroughBufferingAndPause() async throws {
    try await startCachedSong(at: 10)
    testPlayer.appendContextQueue(playables: [songToDownload])
    mockAudioStreamingPlayer.buffering.withLock { $0 = true }
    let prepared = expectation(description: "Stream prepared")
    mockMusicPlayable.expectationDidStartPlaying = prepared
    testPlayer.playNext()
    await fulfillment(of: [prepared], timeout: 2)
    mockMusicPlayable.expectationDidStartPlaying = nil
    for _ in 0..<150 {
      if mockAudioStreamingPlayer.starts.withLock({ $0.last?.url }) == Helper.testURL { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(mockAudioStreamingPlayer.starts.withLock { $0.last?.url }, Helper.testURL)
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 0)

    testPlayer.pause()
    mockAudioStreamingPlayer.buffering.withLock { $0 = false }
    backendPlayer.audioPlayerStateChanged(player: mockAudioStreamingPlayer, with: .playing, previous: .bufferring)
    try await Task.sleep(for: .milliseconds(80))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 0)
    testPlayer.play()
    for _ in 0..<100 {
      if mockAudioStreamingPlayer.volume >= 0.999 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(mockAudioStreamingPlayer.volume, 1, accuracy: 0.001)
  }

  func testSlowStreamCannotReplaceALaterCachedSelection() async throws {
    let resolving = expectation(description: "Resolving outgoing selection")
    var reply: CheckedContinuation<URL, Never>?
    backendApi.resolveStream = {
      await withCheckedContinuation { reply = $0; resolving.fulfill() }
    }
    testPlayer.play(context: PlayContext(name: "Slow stream", playables: [songToDownload]))
    await fulfillment(of: [resolving], timeout: 2)
    testPlayer.play(context: PlayContext(name: "Cached selection", playables: [songCached]))
    reply?.resume(returning: Helper.testURL)
    try await Task.sleep(for: .milliseconds(100))
    let cachedURL = try XCTUnwrap(library.getFileURL(forPlayable: songCached))
    XCTAssertEqual(mockAudioStreamingPlayer.starts.withLock { $0.map { $0.url } }, [cachedURL])
    XCTAssertEqual(testPlayer.playType, .cache)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testEngineRestartResumesEarlyFractionalPositionWithResumeSettingDisabled() async throws {
    storage.settings.user.isPlayerSongPlaybackResumeEnabled = false
    try await startCachedSong(at: 5.25)
    testPlayer.pause()
    let count = songCached.playCount
    mockAudioStreamingPlayer.isStopped = true
    mockAudioStreamingPlayer.mockElapsedTime = 0
    testPlayer.play()
    let url = try XCTUnwrap(library.getFileURL(forPlayable: songCached))
    backendPlayer.didStartPlaying(url: url.absoluteString)
    XCTAssertEqual(testPlayer.elapsedTime, 5.25, accuracy: 0.01)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertEqual(songCached.playCount, count)
  }

  func testAudioInterruptionResumesWithoutRestartingTrack() async throws {
    try await startCachedSong(at: 42.75)
    let session = AudioSessionHandler()
    session.musicPlayer = testMusicPlayer
    session.handleAudioSessionInterruption(notification: NSNotification(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)]))
    XCTAssertFalse(testPlayer.isPlaying)
    session.handleAudioSessionInterruption(notification: NSNotification(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
                 AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)]))
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.elapsedTime, 42.75, accuracy: 0.01)
  }

  func testUnexpectedEngineErrorRecreatesPlayerAtCurrentPosition() async throws {
    storage.settings.user.isPlayerSongPlaybackResumeEnabled = false
    try await startCachedSong(at: 87.25)
    let oldEngine = try XCTUnwrap(mockAudioStreamingPlayer)
    let count = songCached.playCount
    // The real recovery factory creates a fresh engine whose progress starts at zero.
    mockAudioStreamingPlayer = MOCK_AudioStreamingPlayer()
    backendPlayer.triggerReinsertPlayableCB = { self.testMusicPlayer.play() }
    let restarted = expectation(description: "Recovered player prepared")
    mockMusicPlayable.expectationDidStartPlaying = restarted
    backendPlayer.audioPlayerUnexpectedError(player: oldEngine, error: .audioSystemError(.engineFailure))
    await fulfillment(of: [restarted], timeout: 3)
    mockMusicPlayable.expectationDidStartPlaying = nil
    let url = try XCTUnwrap(library.getFileURL(forPlayable: songCached))
    backendPlayer.didStartPlaying(url: url.absoluteString)
    XCTAssertEqual(testPlayer.elapsedTime, 87.25, accuracy: 0.01)
    XCTAssertEqual(songCached.playCount, count)
    XCTAssertTrue(testPlayer.isPlaying)
    // Late callbacks from the disposed engine must not interrupt the replacement.
    backendPlayer.audioPlayerUnexpectedError(player: oldEngine, error: .other)
    backendPlayer.audioPlayerDidFinishPlaying(player: oldEngine,
      entryId: AudioEntryId(id: url.absoluteString), stopReason: .eof, progress: 87.25, duration: 180)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertEqual(testPlayer.elapsedTime, 87.25, accuracy: 0.01)
  }

  func testInterruptionDoesNotStartManuallyPausedTrack() async throws {
    try await startCachedSong(at: 42.75)
    testPlayer.pause()
    let session = AudioSessionHandler()
    session.musicPlayer = testMusicPlayer
    session.handleAudioSessionInterruption(notification: NSNotification(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.began.rawValue)]))
    session.handleAudioSessionInterruption(notification: NSNotification(
      name: AVAudioSession.interruptionNotification, object: nil,
      userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: AVAudioSession.InterruptionType.ended.rawValue),
                 AVAudioSessionInterruptionOptionKey: NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue)]))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.elapsedTime, 42.75, accuracy: 0.01)
  }

  func testNonEOFStopDoesNotAdvanceQueue() async throws {
    try await startCachedSong(at: 42.75)
    testPlayer.appendContextQueue(playables: [songToDownload])
    let url = try XCTUnwrap(library.getFileURL(forPlayable: songCached))
    for reason in [AudioPlayerStopReason.userAction, .error, .disposed] {
      backendPlayer.audioPlayerDidFinishPlaying(player: mockAudioStreamingPlayer,
        entryId: AudioEntryId(id: url.absoluteString), stopReason: reason, progress: 42.75, duration: 180)
    }
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertTrue(backendPlayer.canBeContinued)
  }

  func testGaplessFinishUpdatesCurrentSongAndNotifiesUIOnce() async throws {
    let songs = playlistAllCached.playables
    for (index, song) in songs.enumerated() {
      markAsCached(playable: song, cacheName: "gapless-test-\(index)")
    }
    testPlayer.play(context: PlayContext(name: "Gapless", playables: songs))
    let url = try XCTUnwrap(library.getFileURL(forPlayable: songs[0]))
    backendPlayer.didStartPlaying(url: url.absoluteString)
    for _ in 0..<5 { await Task.yield() }
    let started = expectation(description: "Next song notifies player UI")
    started.assertForOverFulfill = true
    mockMusicPlayable.expectationDidStartPlaying = started
    backendPlayer.audioPlayerDidFinishPlaying(player: mockAudioStreamingPlayer,
      entryId: AudioEntryId(id: url.absoluteString), stopReason: .none, progress: 180, duration: 180)
    await fulfillment(of: [started], timeout: 3)
    XCTAssertEqual(testPlayer.currentlyPlaying, songs[1])
    // A duplicate finish for the old entry must not skip another song.
    backendPlayer.audioPlayerDidFinishPlaying(player: mockAudioStreamingPlayer,
      entryId: AudioEntryId(id: url.absoluteString), stopReason: .eof, progress: 180, duration: 180)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(testPlayer.currentlyPlaying, songs[1])
    mockMusicPlayable.expectationDidStartPlaying = nil
  }

  func testShuffleSurvivesNewContextAndPlayerRecreation() {
    let songs = playlistAllCached.playables
    testPlayer.playShuffled(context: PlayContext(name: "First", playables: songs))
    testPlayer.play(context: PlayContext(name: "Second", index: 2, playables: songs))
    XCTAssertTrue(testPlayer.isShuffle)
    XCTAssertEqual(testPlayer.currentlyPlaying, songs[2])
    XCTAssertEqual(testQueueHandler.getAllNextQueueItems().count, songs.count - 1)
    XCTAssertEqual(Set(testQueueHandler.getAllNextQueueItems().map(\.id)), Set(songs.filter { $0 != songs[2] }.map(\.id)))
    let restoredData = library.getPlayerData()
    XCTAssertTrue(restoredData.isShuffle)
    XCTAssertEqual(restoredData.currentItem, songs[2])
    testPlayer.toggleShuffle()
    testPlayer.play(context: PlayContext(name: "Ordered", playables: songs))
    XCTAssertFalse(testPlayer.isShuffle)
    XCTAssertEqual(testQueueHandler.getAllNextQueueItems(), Array(songs.dropFirst()))
    XCTAssertFalse(library.getPlayerData().isShuffle)
  }

  func testRemovedFeaturesIgnoreLegacyPreferences() {
    storage.settings.user.isShowRating = true
    storage.settings.user.streamingFormatWifiPreference = .mp3
    storage.settings.user.streamingFormatCellularPreference = .mp3
    storage.settings.user.cacheTranscodingFormatPreference = .mp3
    storage.settings.user.songsSortSetting = .rating
    XCTAssertFalse(storage.settings.user.isShowRating)
    XCTAssertEqual(storage.settings.user.streamingFormatWifiPreference, .raw)
    XCTAssertEqual(storage.settings.user.streamingFormatCellularPreference, .raw)
    XCTAssertEqual(storage.settings.user.cacheTranscodingFormatPreference, .raw)
    XCTAssertEqual(storage.settings.user.songsSortSetting, .name)
  }

  func testSubsonicURLsRequestOriginalAudioDespiteOldTranscodingArguments() async throws {
    let api = SubsonicServerApi(performanceMonitor: MOCK_PerformanceMonitor(),
                               eventLogger: eventLogger, settings: storage.settings)
    api.provideCredentials(credentials: LoginCredentials(serverUrl: "https://example.invalid",
      username: "fixture", password: "fixture", backendApi: .subsonic))
    api.clientApiVersion.wrappedValue = SubsonicServerApi.defaultClientApiVersionWithToken
    let stream = try await api.generateUrl(forStreamingPlayableId: "song-1",
      maxBitrate: .limit32, formatPreference: .mp3)
    let query = try XCTUnwrap(URLComponents(url: stream, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first(where: { $0.name == "format" })?.value, "raw")
    XCTAssertNil(query.first(where: { $0.name == "maxBitRate" }))
    storage.settings.user.cacheTranscodingFormatPreference = .mp3
    let download = try await api.generateUrl(forDownloadingPlayableId: "song-1")
    XCTAssertEqual(download.lastPathComponent, "download.view")
  }


  func getAccountForSong(atIndex: Int) -> Account {
    let accIndex = cdHelper.seeder.songs[atIndex].accountIndex
    let accSeed = cdHelper.seeder.accounts[accIndex]

    let acc = library.getAccount(info: AccountInfo(
      serverHash: accSeed.serverHash,
      userHash: accSeed.userHash,
      apiType: BackenApiType(rawValue: accSeed.apiType)!
    ))
    return acc
  }

  func prepareWithCachedPlaylist() {
    for song in playlistThreeCached.playables {
      testQueueHandler.appendContextQueue(playables: [song])
    }
  }

  func prepareWithAllSongsCached() {
    for song in playlistAllCached.playables {
      testQueueHandler.appendContextQueue(playables: [song])
    }
  }

  func markAsCached(playable: AbstractPlayable, cacheName: String = "testSong") {
    let relFilePath = URL(string: cacheName)!
    let absFilePath = CacheFileManager.shared.getAbsoluteAmperfyPath(relFilePath: relFilePath)!
    try! CacheFileManager.shared.writeDataExcludedFromBackup(
      data: Data(base64Encoded: "Test", options: .ignoreUnknownCharacters)!,
      to: absFilePath, accountInfo: account.info
    )
    playable.relFilePath = relFilePath
  }

  func prepareNoWaitingQueuePlaying() {
    playerData.removeAllItems()
    fillPlayerWithSomeSongsAndWaitingQueue()
    playerData.setUserQueuePlaying(false)
  }

  func prepareWithWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setUserQueuePlaying(true)
  }

  func fillPlayerWithSomeSongs() {
    for i in 0 ... fillCount - 1 {
      guard let song = library.getSong(
        for: getAccountForSong(atIndex: i),
        id: cdHelper.seeder.songs[i].id
      )
      else { XCTFail(); return }
      testPlayer.appendContextQueue(playables: [song])
    }
  }

  func fillPlayerWithSomeSongsAndWaitingQueue() {
    fillPlayerWithSomeSongs()
    for i in 0 ... 3 {
      guard let song = library.getSong(
        for: getAccountForSong(atIndex: i),
        id: cdHelper.seeder.songs[fillCount + i].id
      )
      else { XCTFail(); return }
      testPlayer.appendUserQueue(playables: [song])
    }
  }

  func checkPlaylistIndexEqualSeedIndex(playlistIndex: Int, seedIndex: Int) {
    guard let song = library.getSong(
      for: getAccountForSong(atIndex: seedIndex),
      id: cdHelper.seeder.songs[seedIndex].id
    )
    else { XCTFail(); return }
    XCTAssertEqual(playerData.contextQueue.playables[playlistIndex].id, song.id)
  }

  func checkQueueItems(queue: [AbstractPlayable], seedIds: [Int]) {
    XCTAssertEqual(queue.count, seedIds.count)
    if queue.count == seedIds.count, !queue.isEmpty {
      for i in 0 ... queue.count - 1 {
        guard let song = library.getSong(
          for: getAccountForSong(atIndex: seedIds[i]),
          id: cdHelper.seeder.songs[seedIds[i]].id
        )
        else { XCTFail(); return }
        let queueId = queue[i].id
        let songId = song.id
        XCTAssertEqual(queueId, songId)
      }
    }
  }

  func checkCurrentlyPlaying(idToBe: Int?) {
    if let idToBe = idToBe {
      guard let song = library.getSong(
        for: getAccountForSong(atIndex: idToBe),
        id: cdHelper.seeder.songs[idToBe].id
      )
      else { XCTFail(); return }
      XCTAssertEqual(testQueueHandler.currentlyPlaying?.id, song.id)
    } else {
      XCTAssertNil(testQueueHandler.currentlyPlaying)
    }
  }

  func checkQueueInfoConsistency() {
    /// -------------------
    /// Prev Queue
    /// -------------------
    let prevQueueCount = testQueueHandler.prevQueueCount
    let prevQueueItemsAll = testQueueHandler.getAllPrevQueueItems()
    XCTAssertEqual(prevQueueCount, prevQueueItemsAll.count)
    for (index, item) in prevQueueItemsAll.enumerated() {
      let atItem = testQueueHandler.getPrevQueueItem(at: index)
      XCTAssertEqual(atItem, item)
    }
    var prevRangItemsAll = testQueueHandler.getPrevQueueItems(from: 0, to: nil)
    XCTAssertEqual(prevRangItemsAll, prevQueueItemsAll)

    if prevQueueCount > 0 {
      prevRangItemsAll = testQueueHandler.getPrevQueueItems(from: 0, to: prevQueueCount - 1)
      XCTAssertEqual(prevRangItemsAll, prevQueueItemsAll)
    }
    if prevQueueCount > 1 {
      let prevRangeItemsBeforeEnd1 = testQueueHandler.getPrevQueueItems(
        from: 0,
        to: prevQueueCount - 2
      )
      XCTAssertEqual(prevRangeItemsBeforeEnd1.count, prevQueueCount - 1)
      XCTAssertEqual(prevRangeItemsBeforeEnd1, Array(prevQueueItemsAll[0 ... prevQueueCount - 2]))
      let prevRangeItemsOff1 = testQueueHandler.getPrevQueueItems(from: 1, to: prevQueueCount - 1)
      XCTAssertEqual(prevRangeItemsOff1.count, prevQueueCount - 1)
      XCTAssertEqual(prevRangeItemsOff1, Array(prevQueueItemsAll[1 ... prevQueueCount - 1]))
      XCTAssertEqual(prevRangeItemsOff1[0], prevQueueItemsAll[1])
    }
    if prevQueueCount > 2 {
      let prevRangeItemsMissingStartAndEnd = testQueueHandler.getPrevQueueItems(
        from: 1,
        to: prevQueueCount - 2
      )
      XCTAssertEqual(prevRangeItemsMissingStartAndEnd.count, prevQueueCount - 2)
      XCTAssertEqual(
        prevRangeItemsMissingStartAndEnd,
        Array(prevQueueItemsAll[1 ... prevQueueCount - 2])
      )
      XCTAssertEqual(prevRangeItemsMissingStartAndEnd[0], prevQueueItemsAll[1])
      XCTAssertEqual(prevRangeItemsMissingStartAndEnd.last!, prevQueueItemsAll[prevQueueCount - 2])
    }
    /// -------------------
    /// User Queue
    /// -------------------
    let userQueueCount = testQueueHandler.userQueueCount
    let userQueueItemsAll = testQueueHandler.getAllUserQueueItems()
    XCTAssertEqual(userQueueCount, userQueueItemsAll.count)
    for (index, item) in userQueueItemsAll.enumerated() {
      let atItem = testQueueHandler.getUserQueueItem(at: index)
      XCTAssertEqual(atItem, item)
    }
    var userRangItemsAll = testQueueHandler.getUserQueueItems(from: 0, to: nil)
    XCTAssertEqual(userRangItemsAll, userQueueItemsAll)

    if userQueueCount > 0 {
      userRangItemsAll = testQueueHandler.getUserQueueItems(from: 0, to: userQueueCount - 1)
      XCTAssertEqual(userRangItemsAll, userQueueItemsAll)
    }
    if userQueueCount > 1 {
      let userRangeItemsBeforeEnd1 = testQueueHandler.getUserQueueItems(
        from: 0,
        to: userQueueCount - 2
      )
      XCTAssertEqual(userRangeItemsBeforeEnd1.count, userQueueCount - 1)
      XCTAssertEqual(userRangeItemsBeforeEnd1, Array(userQueueItemsAll[0 ... userQueueCount - 2]))
      let userRangeItemsOff1 = testQueueHandler.getUserQueueItems(from: 1, to: userQueueCount - 1)
      XCTAssertEqual(userRangeItemsOff1.count, userQueueCount - 1)
      XCTAssertEqual(userRangeItemsOff1, Array(userQueueItemsAll[1 ... userQueueCount - 1]))
      XCTAssertEqual(userRangeItemsOff1[0], userQueueItemsAll[1])
    }
    if userQueueCount > 2 {
      let userRangeItemsMissingStartAndEnd = testQueueHandler.getUserQueueItems(
        from: 1,
        to: userQueueCount - 2
      )
      XCTAssertEqual(userRangeItemsMissingStartAndEnd.count, userQueueCount - 2)
      XCTAssertEqual(
        userRangeItemsMissingStartAndEnd,
        Array(userQueueItemsAll[1 ... userQueueCount - 2])
      )
      XCTAssertEqual(userRangeItemsMissingStartAndEnd[0], userQueueItemsAll[1])
      XCTAssertEqual(userRangeItemsMissingStartAndEnd.last!, userQueueItemsAll[userQueueCount - 2])
    }
    /// -------------------
    /// Next Queue
    /// -------------------
    let nextQueueCount = testQueueHandler.nextQueueCount
    let nextQueueItemsAll = testQueueHandler.getAllNextQueueItems()
    XCTAssertEqual(nextQueueCount, nextQueueItemsAll.count)
    for (index, item) in nextQueueItemsAll.enumerated() {
      let atItem = testQueueHandler.getNextQueueItem(at: index)
      XCTAssertEqual(atItem, item)
    }
    var nextRangItemsAll = testQueueHandler.getNextQueueItems(from: 0, to: nil)
    XCTAssertEqual(nextRangItemsAll, nextQueueItemsAll)

    if nextQueueCount > 0 {
      nextRangItemsAll = testQueueHandler.getNextQueueItems(from: 0, to: nextQueueCount - 1)
      XCTAssertEqual(nextRangItemsAll, nextQueueItemsAll)
    }
    if nextQueueCount > 1 {
      let nextRangeItemsBeforeEnd1 = testQueueHandler.getNextQueueItems(
        from: 0,
        to: nextQueueCount - 2
      )
      XCTAssertEqual(nextRangeItemsBeforeEnd1.count, nextQueueCount - 1)
      XCTAssertEqual(nextRangeItemsBeforeEnd1, Array(nextQueueItemsAll[0 ... nextQueueCount - 2]))
      let nextRangeItemsOff1 = testQueueHandler.getNextQueueItems(from: 1, to: nextQueueCount - 1)
      XCTAssertEqual(nextRangeItemsOff1.count, nextQueueCount - 1)
      XCTAssertEqual(nextRangeItemsOff1, Array(nextQueueItemsAll[1 ... nextQueueCount - 1]))
      XCTAssertEqual(nextRangeItemsOff1[0], nextQueueItemsAll[1])
    }
    if nextQueueCount > 2 {
      let nextRangeItemsMissingStartAndEnd = testQueueHandler.getNextQueueItems(
        from: 1,
        to: nextQueueCount - 2
      )
      XCTAssertEqual(nextRangeItemsMissingStartAndEnd.count, nextQueueCount - 2)
      XCTAssertEqual(
        nextRangeItemsMissingStartAndEnd,
        Array(nextQueueItemsAll[1 ... nextQueueCount - 2])
      )
      XCTAssertEqual(nextRangeItemsMissingStartAndEnd[0], nextQueueItemsAll[1])
      XCTAssertEqual(nextRangeItemsMissingStartAndEnd.last!, nextQueueItemsAll[nextQueueCount - 2])
    }
  }

  // -------------------------------------------------------------

  func testCreation() {
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(testPlayer.isShuffle)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.getAllNextQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.getAllUserQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.elapsedTime, 0.0)
    XCTAssertEqual(testPlayer.duration, 0.0)
    XCTAssertEqual(testPlayer.repeatMode, RepeatMode.off)
    XCTAssertTrue(songDownloader.isNoDownloadRequested())
  }

  func testPlay_EmptyPlaylist() {
    testPlayer.play()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlay_OneCachedSongInPlayer_IsPlayingTrue() {
    testPlayer.appendContextQueue(playables: [songCached])
    testPlayer.play()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testPlay_OneCachedSongInPlayer_NoDownloadRequest() {
    testPlayer.appendContextQueue(playables: [songCached])
    testPlayer.play()
    XCTAssertTrue(songDownloader.isNoDownloadRequested())
  }

  func testPlay_OneSongToDownload_IsPlayingFalse_UntilDownloadfinishes() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    testPlayer.appendContextQueue(playables: [songToDownload])
    testPlayer.play()
    XCTAssertFalse(testPlayer.isPlaying)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songToDownload)
  }

  func testPlay_OneSongToDownload_CheckDownloadRequest() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    testPlayer.isAutoCachePlayedItems = true
    testPlayer.appendContextQueue(playables: [songToDownload])
    testPlayer.play()
    XCTAssertEqual(songDownloader.downloadables.count, 0)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertEqual(songDownloader.downloadables.count, 1)
    XCTAssertEqual(
      (songDownloader.downloadables.first! as! AbstractPlayable).asSong!,
      songToDownload
    )
  }

  func testPlaySong_Cached() {
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testContextName() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    XCTAssertEqual(testPlayer.contextName, "asdf")
  }

  func testContextName_changeContext() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    XCTAssertEqual(testPlayer.contextName, "asdf")
    testPlayer.play(context: PlayContext(name: "uio qwe", playables: [songCached]))
    XCTAssertEqual(testPlayer.contextName, "uio qwe")
  }

  func testContextName_insertContext() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    testPlayer.insertContextQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.contextName, "Mixed Context")
  }

  func testContextName_appendContext() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    testPlayer.appendContextQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.contextName, "Mixed Context")
  }

  func testContextName_insertUser() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    testPlayer.insertUserQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.contextName, "asdf")
  }

  func testContextName_appendUser() {
    testPlayer.play(context: PlayContext(name: "asdf", playables: [songCached]))
    testPlayer.appendUserQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.contextName, "asdf")
  }

  func testPlaySong_CheckPlaylistClear() {
    prepareWithCachedPlaylist()
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.getAllUserQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.getAllNextQueueItems(), [AbstractPlayable]())
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testPlaySongInPlaylistAt_EmptyPlaylist() {
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 5))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: -1))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlaySongInPlaylistAt_Cached_FullPlaylist() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 3)
  }

  func testPlaySongInPlaylistAt_FetchSuccess_FullPlaylist() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 1))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 2)
  }

  func testPause_EmptyPlaylist() {
    testMusicPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testPause_CurrentlyPlaying() {
    testPlayer.appendContextQueue(playables: [songCached])
    testPlayer.play()
    testMusicPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testPause_CurrentlyPaused() {
    testPlayer.appendContextQueue(playables: [songCached])
    testMusicPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testPause_SongInMiddleOfPlaylist() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 3)
    testMusicPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 3)
    testPlayer.play()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 3)
  }

  func testAddToPlaylist() {
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    testPlayer.appendContextQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    testPlayer.appendContextQueue(playables: [songToDownload])
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    testPlayer.appendContextQueue(playables: [songCached])
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    testPlayer.appendContextQueue(playables: [songToDownload])
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 3)
  }

  func testPlaylistClear_EmptyPlaylist() {
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlaylistClear_EmptyPlaylist_WaitingQueueHasEntries() {
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlaylistClear_EmptyPlaylist_WaitingQueueHasEntries2() {
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId1])
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlaylistClear_EmptyPlaylist_WaitingQueueHasEntries3() {
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.insertUserQueue(playables: [songId0])
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlaylistClear_EmptyPlaylist_WaitingQueueHasEntries4() {
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.insertUserQueue(playables: [songId0])
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.insertUserQueue(playables: [songId1])
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems()[0], songId1)
  }

  func testPlaylistClear_EmptyPlaylist_WaitingQueueHasEntries5() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId1])
    testPlayer.play()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 3.0)
    XCTAssertTrue(testPlayer.isPlaying)
    testPlayer.clearContextQueue()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlaylistClear_FilledPlaylist() {
    prepareWithCachedPlaylist()
    testPlayer.clearContextQueue()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlaylistClear_FilledPlaylist_WaitingQueuePlaying() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    prepareWithCachedPlaylist()
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId1])
    testPlayer.clearContextQueue()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlaylistClear_FilledPlaylist_WaitingQueuePlaying2() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    prepareWithCachedPlaylist()
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId1])
    testPlayer.playNext()
    testPlayer.clearContextQueue()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId0)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Latest selection prepared")
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.playNext()

    testPlayer.clearContextQueue()
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.appendContextQueue(playables: [songId1, songId2, songId3])
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying2() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Latest selection prepared")
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.playNext()

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1, songId2, songId3]))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying8() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1, songId2, songId3]))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlaySong_WaitingQueuePlaying8() {
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlaySong_WaitingQueuePlaying9() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Latest selection prepared")
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.appendUserQueue(playables: [songId1])
    testPlayer.appendUserQueue(playables: [songId2])
    testPlayer.playNext()

    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId3]))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 3.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId3)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying3() {
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.appendUserQueue(playables: [songId1])
    testPlayer.appendUserQueue(playables: [songId2])
    testPlayer.playNext()

    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId3]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId3)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying4() {
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.playNext()

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying5() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Latest selection prepared")
    prepareWithCachedPlaylist()
    playerData.setCurrentIndex(1)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])
    testPlayer.playNext()

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1]))
    XCTAssertFalse(testPlayer.isPlaying)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying, songId1)
  }

  func testPlayMulitpleSongs_WaitingQueuePlaying6() {
    prepareWithCachedPlaylist()
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId0]))

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId1.id)
  }

  func testPlayMulitpleSongs_userQueueHasElements_notUserQueuePlaying() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId1.id)
  }

  func testPlayMulitpleSongs_userQueueHasElements_notUserQueuePlaying2() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(name: "", playables: [songId1, songId2, songId3]))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId1.id)
  }

  func testPlayMulitpleSongs_userQueueHasElements_notUserQueuePlaying3() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      index: 1,
      playables: [songId1, songId2, songId3]
    ))
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId2.id)
  }

  func testPlayMulitpleSongs_userQueueHasElements_notUserQueuePlaying4() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId4 = library.getSong(for: account, id: cdHelper.seeder.songs[4].id)
    else { XCTFail(); return }
    guard let songId5 = library.getSong(for: account, id: cdHelper.seeder.songs[5].id)
    else { XCTFail(); return }
    testPlayer.appendUserQueue(playables: [songId0, songId4, songId5])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      index: 2,
      playables: [songId1, songId2, songId3]
    ))
    XCTAssertFalse(testPlayer.isPlaying)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId3.id)
    XCTAssertEqual(testPlayer.getAllUserQueueItems()[0].id, songId4.id)
    XCTAssertEqual(testPlayer.getAllUserQueueItems()[1].id, songId5.id)
  }

  func testPlayMulitpleSongs_switchPlayerMode_toMusic() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId4 = library.getSong(for: account, id: cdHelper.seeder.songs[4].id)
    else { XCTFail(); return }
    guard let songId5 = library.getSong(for: account, id: cdHelper.seeder.songs[5].id)
    else { XCTFail(); return }
    testPlayer.appendContextQueue(playables: [songId0, songId4, songId5])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.insertPodcastQueue(playables: [songId1, songId2, songId3])
    testPlayer.setPlayerMode(.podcast)

    guard let songId7 = library.getSong(for: account, id: cdHelper.seeder.songs[7].id)
    else { XCTFail(); return }
    guard let songId8 = library.getSong(for: account, id: cdHelper.seeder.songs[8].id)
    else { XCTFail(); return }
    guard let songId9 = library.getSong(for: account, id: cdHelper.seeder.songs[9].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      index: 1,
      playables: [songId7, songId8, songId9]
    ))
    XCTAssertEqual(testPlayer.playerMode, PlayerMode.music)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId8.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId7.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId9.id)

    testPlayer.setPlayerMode(.podcast)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId1.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId2.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[1].id, songId3.id)
  }

  func testPlayMulitpleSongs_switchPlayerMode_toMusic2() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId4 = library.getSong(for: account, id: cdHelper.seeder.songs[4].id)
    else { XCTFail(); return }
    guard let songId5 = library.getSong(for: account, id: cdHelper.seeder.songs[5].id)
    else { XCTFail(); return }
    testPlayer.appendContextQueue(playables: [songId0, songId4, songId5])
    playerData.setCurrentIndex(0)

    testPlayer.setPlayerMode(.podcast)
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.insertPodcastQueue(playables: [songId1, songId2, songId3])
    playerData.setCurrentIndex(1)

    guard let songId7 = library.getSong(for: account, id: cdHelper.seeder.songs[7].id)
    else { XCTFail(); return }
    guard let songId8 = library.getSong(for: account, id: cdHelper.seeder.songs[8].id)
    else { XCTFail(); return }
    guard let songId9 = library.getSong(for: account, id: cdHelper.seeder.songs[9].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      type: .music,
      index: 2,
      playables: [songId7, songId8, songId9]
    ))
    XCTAssertEqual(testPlayer.playerMode, PlayerMode.music)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId9.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId7.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[1].id, songId8.id)

    testPlayer.setPlayerMode(.podcast)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId2.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId1.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId3.id)
  }

  func testPlayMulitpleSongs_switchPlayerMode_toPodcast() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId4 = library.getSong(for: account, id: cdHelper.seeder.songs[4].id)
    else { XCTFail(); return }
    guard let songId5 = library.getSong(for: account, id: cdHelper.seeder.songs[5].id)
    else { XCTFail(); return }
    testPlayer.appendContextQueue(playables: [songId0, songId4, songId5])

    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.insertPodcastQueue(playables: [songId1, songId2, songId3])

    guard let songId7 = library.getSong(for: account, id: cdHelper.seeder.songs[7].id)
    else { XCTFail(); return }
    guard let songId8 = library.getSong(for: account, id: cdHelper.seeder.songs[8].id)
    else { XCTFail(); return }
    guard let songId9 = library.getSong(for: account, id: cdHelper.seeder.songs[9].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      type: .podcast,
      index: 1,
      playables: [songId7, songId8, songId9]
    ))
    XCTAssertEqual(testPlayer.playerMode, PlayerMode.podcast)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId8.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId7.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId9.id)

    testPlayer.setPlayerMode(.music)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 2)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId0.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId4.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[1].id, songId5.id)
  }

  func testPlayMulitpleSongs_switchPlayerMode_toPodcast2() {
    playerData.removeAllItems()
    playerData.setUserQueuePlaying(false)
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId4 = library.getSong(for: account, id: cdHelper.seeder.songs[4].id)
    else { XCTFail(); return }
    guard let songId5 = library.getSong(for: account, id: cdHelper.seeder.songs[5].id)
    else { XCTFail(); return }
    testPlayer.appendContextQueue(playables: [songId0, songId4, songId5])
    playerData.setCurrentIndex(1)

    testPlayer.setPlayerMode(.podcast)
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }
    guard let songId2 = library.getSong(for: account, id: cdHelper.seeder.songs[2].id)
    else { XCTFail(); return }
    guard let songId3 = library.getSong(for: account, id: cdHelper.seeder.songs[3].id)
    else { XCTFail(); return }
    testPlayer.insertPodcastQueue(playables: [songId1, songId2, songId3])
    playerData.setCurrentIndex(0)

    guard let songId7 = library.getSong(for: account, id: cdHelper.seeder.songs[7].id)
    else { XCTFail(); return }
    guard let songId8 = library.getSong(for: account, id: cdHelper.seeder.songs[8].id)
    else { XCTFail(); return }
    guard let songId9 = library.getSong(for: account, id: cdHelper.seeder.songs[9].id)
    else { XCTFail(); return }
    testPlayer.play(context: PlayContext(
      name: "",
      type: .podcast,
      index: 2,
      playables: [songId7, songId8, songId9]
    ))
    XCTAssertEqual(testPlayer.playerMode, PlayerMode.podcast)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 0)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId9.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId7.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[1].id, songId8.id)

    testPlayer.setPlayerMode(.music)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 1)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 1)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songId4.id)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems()[0].id, songId0.id)
    XCTAssertEqual(testPlayer.getAllNextQueueItems()[0].id, songId5.id)
  }

  func testPlay_ContextNameChanges() {
    playerData.removeAllItems()
    guard let songId0 = library.getSong(
      for: getAccountForSong(atIndex: 0),
      id: cdHelper.seeder.songs[0].id
    )
    else { XCTFail(); return }
    guard let songId1 = library.getSong(
      for: getAccountForSong(atIndex: 1),
      id: cdHelper.seeder.songs[1].id
    )
    else { XCTFail(); return }

    testPlayer.play(context: PlayContext(name: "Blub", playables: [songId0, songId1]))
    XCTAssertEqual(testPlayer.contextName, "Blub")
    testPlayer.setPlayerMode(.podcast)
    XCTAssertEqual(testPlayer.contextName, "Podcasts")
    testPlayer.appendContextQueue(playables: [songId0])
    XCTAssertEqual(testPlayer.contextName, "Podcasts")
    testPlayer.setPlayerMode(.music)
    XCTAssertEqual(testPlayer.contextName, "Mixed Context")

    testPlayer.play(context: PlayContext(name: "YYYY", playables: [songId0, songId1]))
    XCTAssertEqual(testPlayer.contextName, "YYYY")
    testPlayer.play(context: PlayContext(
      name: "GoGo Podcasts",
      type: .podcast,
      playables: [songId0, songId1]
    ))
    XCTAssertEqual(testPlayer.contextName, "Podcasts")
    testPlayer.setPlayerMode(.music)
    XCTAssertEqual(testPlayer.contextName, "YYYY")

    testPlayer.play(context: PlayContext(name: "BBBB", playables: [songId0, songId1]))
    XCTAssertEqual(testPlayer.contextName, "BBBB")
    testPlayer.appendPodcastQueue(playables: [songId0])
    XCTAssertEqual(testPlayer.contextName, "BBBB")
    testPlayer.setPlayerMode(.podcast)
    XCTAssertEqual(testPlayer.contextName, "Podcasts")
    testPlayer.insertPodcastQueue(playables: [songId0])
    testPlayer.setPlayerMode(.music)
    XCTAssertEqual(testPlayer.contextName, "BBBB")

    testPlayer.setPlayerMode(.music)
    testPlayer.insertContextQueue(playables: [songId0])
    XCTAssertEqual(testPlayer.contextName, "Mixed Context")
  }

  func testSeek_EmptyPlaylist() {
    testPlayer.seek(toSecond: 3.0)
    XCTAssertEqual(testPlayer.elapsedTime, 0.0)
  }

  func testSeek_FilledPlaylist() {
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))
    testPlayer.seek(toSecond: 3.0)
    backendPlayer
      .didStartPlaying(
        url: library.getFileURL(forPlayable: testPlayer.currentlyPlaying!)!
          .absoluteString
      )
    let elapsedTime = testPlayer.elapsedTime
    XCTAssertEqual(elapsedTime, 3.0)
  }

  func testRepeatedLyricSeeksWhileBufferingReachTheEngineAndPublishLatestTime() async throws {
    try await startCachedSong(at: 37)
    backendPlayer.setVisualUpdatesEnabled(true)
    testPlayer.seek(toSecond: 42.001)
    mockAudioStreamingPlayer.buffering.withLock { $0 = true }
    // The first seek is still buffering when the listener taps later, then earlier.
    testPlayer.seek(toSecond: 86.125)
    testPlayer.seek(toSecond: 18.047)
    XCTAssertEqual(mockAudioStreamingPlayer.mockElapsedTime, 18.047)
    XCTAssertEqual(testPlayer.elapsedTime, 18.047)
    XCTAssertEqual(mockMusicPlayable.lyricsTimes.last?.seconds ?? -1, 18.047, accuracy: 0.001)
    mockAudioStreamingPlayer.buffering.withLock { $0 = false }
    backendPlayer.audioPlayerStateChanged(player: mockAudioStreamingPlayer, with: .playing, previous: .bufferring)
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(testPlayer.elapsedTime, 18.047, "Resuming must not replay an older seek")
  }

  func testPausedLyricSeekPublishesWithoutWaitingForPlaybackTimer() async throws {
    try await startCachedSong(at: 37)
    backendPlayer.setVisualUpdatesEnabled(true)
    testPlayer.pause()
    try await Task.sleep(for: .milliseconds(150))
    testPlayer.seek(toSecond: 65.125)
    XCTAssertEqual(mockAudioStreamingPlayer.mockElapsedTime, 65.125)
    XCTAssertEqual(mockMusicPlayable.lyricsTimes.last?.seconds, 65.125)
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(mockAudioStreamingPlayer.isPlaying)
  }

  func testPlayPreviousOrReplay_EmptyPlaylist() {
    testPlayer.playPreviousOrReplay()
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlayPreviousOrReplay_Previous() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    testPlayer.playPreviousOrReplay()
    XCTAssertEqual(playerData.currentIndex, 2)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 2)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 6)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.elapsedTime, 0.0)
  }

  func testPlayPreviousOrReplay_Replay() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    XCTAssertFalse(testPlayer.isStopInsteadOfPause)
    testPlayer.seek(toSecond: 10.0)

    backendPlayer
      .didStartPlaying(
        url: library.getFileURL(forPlayable: testPlayer.currentlyPlaying!)!
          .absoluteString
      )

    testPlayer.playPreviousOrReplay()
    XCTAssertTrue(testPlayer.isSkipAvailable)
    XCTAssertEqual(playerData.currentIndex, 3)
    XCTAssertEqual(testPlayer.getAllPrevQueueItems().count, 3)
    XCTAssertEqual(testPlayer.getAllUserQueueItems().count, 0)
    XCTAssertEqual(testPlayer.getAllNextQueueItems().count, 5)
    checkQueueInfoConsistency()
    XCTAssertEqual(testPlayer.elapsedTime, 0.0)
  }

  func testPlayPreviousOrReplay_Radio_Previous() {
    let radios = library.getRadios(for: account)
    XCTAssertEqual(radios.count, 4)
    testPlayer.play(context: PlayContext(name: "Radios", playables: radios))
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    testPlayer.seek(toSecond: 10.0)
    testPlayer.playPreviousOrReplay()
    XCTAssertEqual(playerData.currentIndex, 2)
  }

  func testPauseRadio() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Selected station prepared")

    let radios = library.getRadios(for: account)
    XCTAssertEqual(radios.count, 4)
    testPlayer.play(context: PlayContext(name: "Radios", playables: radios))
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isStopInsteadOfPause)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 3)
    testPlayer.pause()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(testPlayer.isSkipAvailable)
    XCTAssertEqual(playerData.currentIndex, 3)
  }

  func testRadioInvalidUrl() {
    let radios = library.getRadios(for: account)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Normal Play")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    testPlayer.play(context: PlayContext(name: "Radios", playables: radios))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Invalid URL")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)

    XCTAssertTrue(testPlayer.isStopInsteadOfPause)
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 1)
  }

  func testPlayPrevious_EmptyPlaylist() {
    testMusicPlayer.playPrevious()
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testPlayPrevious_Normal() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 2)
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 1)
  }

  func testPlayPrevious_AtStart() {
    prepareWithCachedPlaylist()
    testPlayer.play()
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 0)
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 0)
  }

  func testPlayPrevious_RepeatAll() {
    prepareWithCachedPlaylist()
    testPlayer.setRepeatMode(.all)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    testMusicPlayer.playPrevious()
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 8)
  }

  func testPlayPrevious_RepeatAll_OnlyOneSong() {
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))
    testPlayer.setRepeatMode(.all)
    testMusicPlayer.playPrevious()
    testMusicPlayer.playPrevious()
    XCTAssertEqual(playerData.currentIndex, 0)
  }

  func testPlayPrevious_StartPlayIfPaused() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    testMusicPlayer.pause()
    testMusicPlayer.playPrevious()
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testPlayPrevious_IsPlayingStaysTrue() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    testMusicPlayer.playPrevious()
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testPlayNext_EmptyPlaylist() {
    testPlayer.playNext()
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  private func startAutoplayFixture() async throws {
    savedAutoplayEnabled = storage.settings.user.isAutoplayEnabled
    testPlayer.setAutoplayEnabled(false)
    testPlayer.play(context: PlayContext(name: "Single song", playables: [songCached]))
    for _ in 0..<200 {
      if testPlayer.isPlaying, backendPlayer.canBeContinued { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertTrue(backendPlayer.canBeContinued)
  }

  func testNextAtQueueEndPausesAndKeepsSongPosition() async throws {
    try await startAutoplayFixture()
    mockAudioStreamingPlayer.mockElapsedTime = 23
    testPlayer.playNext()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(mockAudioStreamingPlayer.isStopped)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertEqual(playerData.currentIndex, 0)
    XCTAssertEqual(testPlayer.elapsedTime, 23)
    testPlayer.play()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.elapsedTime, 23)
  }

  func testNextDuringFirstPreparationStaysPausedAfterEngineStarts() async throws {
    savedAutoplayEnabled = storage.settings.user.isAutoplayEnabled
    testPlayer.setAutoplayEnabled(false)
    testPlayer.play(context: PlayContext(name: "Cold-start single song", playables: [songCached]))
    testPlayer.playNext()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertFalse(mockAudioStreamingPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertEqual(playerData.currentIndex, 0)
  }

  func testAutoplayPrefetchDeduplicatesAndKeepsExplicitQueueSeparate() async throws {
    try await startAutoplayFixture()
    let recommended = playlistAllCached.playables.filterSongs().filter { $0 != songCached }.prefix(2)
    let ready = expectation(description: "recommendations ready")
    testMusicPlayer.autoplayCB = { song, _, _ in
      ready.fulfill()
      return [song] + Array(recommended) + Array(recommended)
    }
    testPlayer.setAutoplayEnabled(true)
    await fulfillment(of: [ready], timeout: 2)
    XCTAssertEqual(testPlayer.autoplayQueue.count, recommended.count)
    XCTAssertEqual(testPlayer.nextQueueCount, 0)
    XCTAssertEqual(testMusicPlayer.upcomingPlayablesForPreparation(limit: 3).map { $0.uniqueID },
                   recommended.map { $0.uniqueID })
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    testPlayer.setAutoplayEnabled(false)
    XCTAssertTrue(testPlayer.autoplayQueue.isEmpty)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testAutoplayContinuesAfterExplicitQueueAndRespectsUserQueue() async throws {
    try await startAutoplayFixture()
    let songs = playlistAllCached.playables.filterSongs().filter { $0 != songCached }
    let recommended = songs[0]
    let ready = expectation(description: "recommendations ready")
    testMusicPlayer.autoplayCB = { _, _, _ in ready.fulfill(); return [recommended] }
    testPlayer.setAutoplayEnabled(true)
    await fulfillment(of: [ready], timeout: 2)
    testMusicPlayer.autoplayCB = nil
    testPlayer.insertUserQueue(playables: [songs[1]])
    testPlayer.playNext()
    XCTAssertEqual(testPlayer.currentlyPlaying, songs[1])
    testPlayer.playNext()
    XCTAssertEqual(testPlayer.currentlyPlaying, recommended)
    XCTAssertTrue(testPlayer.autoplayQueue.isEmpty)
  }

  func testPendingAutoplayCoalescesNextAndCannotOverrideNewContext() async throws {
    try await startAutoplayFixture()
    var reply: CheckedContinuation<Void, Never>?
    let staleSong = songCached!
    var requests = 0
    let started = expectation(description: "request started")
    testMusicPlayer.autoplayCB = { _, _, _ in
      requests += 1
      await withCheckedContinuation { reply = $0; started.fulfill() }
      return [staleSong]
    }
    testPlayer.setAutoplayEnabled(true)
    await fulfillment(of: [started], timeout: 2)
    testPlayer.playNext()
    testPlayer.playNext()
    XCTAssertEqual(requests, 1)
    let other = playlistAllCached.playables.filterSongs().first { $0 != songCached }!
    testMusicPlayer.autoplayCB = nil
    testPlayer.play(context: PlayContext(name: "New selection", playables: [other]))
    reply?.resume()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(testPlayer.currentlyPlaying, other)
    XCTAssertTrue(testPlayer.autoplayQueue.isEmpty)
    XCTAssertEqual(testPlayer.contextName, "New selection")
  }

  func testPauseCancelsPendingAutoplayAdvance() async throws {
    try await startAutoplayFixture()
    var reply: CheckedContinuation<Void, Never>?
    let started = expectation(description: "request started")
    testMusicPlayer.autoplayCB = { _, _, _ in
      await withCheckedContinuation { reply = $0; started.fulfill() }
      return self.playlistAllCached.playables.filterSongs()
    }
    testPlayer.setAutoplayEnabled(true)
    await fulfillment(of: [started], timeout: 2)
    testPlayer.playNext()
    testPlayer.pause()
    reply?.resume()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    XCTAssertTrue(testPlayer.autoplayQueue.isEmpty)
  }

  func testAutoplayEmptyOrFailedRecommendationPausesWithoutResettingQueue() async throws {
    try await startAutoplayFixture()
    testMusicPlayer.autoplayCB = { _, _, _ in [] }
    testPlayer.setAutoplayEnabled(true)
    testPlayer.playNext()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
    testMusicPlayer.autoplayCB = { _, _, _ in throw BackendError.notSupported }
    testPlayer.play()
    testPlayer.playNext()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, songCached)
  }

  func testRepeatModeSuppressesAutoplayAndDisablingKeepsUserSongs() async throws {
    try await startAutoplayFixture()
    var requests = 0
    testMusicPlayer.autoplayCB = { _, _, _ in requests += 1; return [] }
    testPlayer.setRepeatMode(.all)
    testPlayer.setAutoplayEnabled(true)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(requests, 0)
    XCTAssertTrue(testPlayer.autoplayQueue.isEmpty)
    testPlayer.insertUserQueue(playables: [songToDownload])
    testPlayer.setAutoplayEnabled(false)
    XCTAssertEqual(testPlayer.getAllUserQueueItems(), [songToDownload])
  }

  func testLocalAutoplayFallbackUsesAccountCacheAndExclusions() {
    let songs = library.getAutoplaySongs(seed: songCached,
      excluding: [songCached.managedObject.objectID], recent: [], count: 4, onlyCached: true)
    XCTAssertFalse(songs.isEmpty)
    XCTAssertLessThanOrEqual(songs.count, 4)
    XCTAssertTrue(songs.allSatisfy { $0.account == account && $0.isCached && $0 != songCached })
    XCTAssertEqual(Set(songs.map { $0.managedObject.objectID }).count, songs.count)
  }

  func testPlayNext_Normal() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 4)
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 5)
  }

  func testPlayNext_AtStart() {
    prepareWithCachedPlaylist()
    testPlayer.play()
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 1)
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 2)
  }

  func testPlayNext_RepeatAll() {
    prepareWithCachedPlaylist()
    testPlayer.setRepeatMode(.all)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 7))
    testPlayer.playNext()
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 1)
  }

  func testPlayNext_RepeatAll_OnlyOneSong() {
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))
    testPlayer.setRepeatMode(.all)
    testPlayer.playNext()
    testPlayer.playNext()
    XCTAssertEqual(playerData.currentIndex, 0)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, songCached.id)
  }

  func testPlayNext_StartPlayIfPaused() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "First song prepared")
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2)
    testMusicPlayer.pause()
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Next song prepared")
    testPlayer.playNext()
    XCTAssertFalse(testPlayer.isPlaying)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 3.0)
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testPlayNext_IsPlayingStaysTrue() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "First song prepared")
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2)
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "Next song prepared")
    testPlayer.playNext()
    XCTAssertTrue(testPlayer.isPlaying)
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testStop_EmptyPlaylist() {
    testPlayer.stop()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying, nil)
  }

  func testStop_Playing() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 6))
    testPlayer.stop()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistThreeCached.playables[0].id)
  }

  func testStop_AlreadyStopped() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 6))
    testPlayer.stop()
    testPlayer.stop()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(playerData.currentIndex, 0)
  }

  func testTogglePlay_EmptyPlaylist() {
    testPlayer.togglePlayPause()
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.togglePlayPause()
    XCTAssertFalse(testPlayer.isPlaying)
    testPlayer.togglePlayPause()
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testTogglePlay_AfterPlay() {
    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 6))
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    testPlayer.togglePlayPause()
    XCTAssertFalse(testPlayer.isPlaying)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    testPlayer.togglePlayPause()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)

    testPlayer.togglePlayPause()
    XCTAssertFalse(testPlayer.isPlaying)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "download is triggered")
    testPlayer.togglePlayPause()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
  }

  func testRemoveFromPlaylist_RemoveNotCurrentSong() {
    prepareWithCachedPlaylist()
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .prev, index: 2))
    XCTAssertEqual(playerData.currentIndex, 3)
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 1))
    XCTAssertEqual(playerData.currentIndex, 3)
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 0))
    XCTAssertEqual(playerData.currentIndex, 3)
    testPlayer.removePlayable(at: PlayerIndex(queueType: .prev, index: 0))
    XCTAssertEqual(playerData.currentIndex, 2)
  }

  func testPlayer_InsertNextInMainQueue_emptyMainQueue() {
    testPlayer.clearContextQueue()
    playerData.setCurrentIndex(0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [])
    testPlayer.insertContextQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [])
  }

  func testPlayer_InsertNextInMainQueue_emptyMainQueue_userQueuePlaing() {
    playerData.setCurrentIndex(0)
    testPlayer.insertUserQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [])
    checkQueueInfoConsistency()
    testPlayer.insertContextQueue(playables: [songToDownload])
    checkCurrentlyPlaying(idToBe: 4)
    XCTAssertEqual(playerData.currentIndex, -1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [])
    checkQueueInfoConsistency()
  }

  func testPlayer_InsertNextInMainQueue_WithWaitingQueuePlaying_nextEmpty() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.insertContextQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_InsertNextInMainQueue_noWaitingQueuePlaying_nextEmpty() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.insertContextQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_InsertNextInMainQueue_WithWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.insertContextQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_InsertNextInMainQueue_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.insertContextQueue(playables: [songCached])
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_AppendNextInMainQueue_WithWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.appendContextQueue(playables: [songToDownload])
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4, 0])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_AppendNextInMainQueue_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.appendContextQueue(playables: [songToDownload])
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4, 0])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPrev_WithWaitingQueue_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(3)
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.setRepeatMode(.all)
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPrev_WithWaitingQueue_withWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    checkCurrentlyPlaying(idToBe: 5)
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.setRepeatMode(.all)
    checkCurrentlyPlaying(idToBe: 5)
    testMusicPlayer.playPrevious()
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayNext_WithWaitingQueue_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayNext_WithWaitingQueue_withWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    checkCurrentlyPlaying(idToBe: 5)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 7)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [8])
    checkQueueInfoConsistency()
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    playerData.setCurrentIndex(4)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()
    testPlayer.setRepeatMode(.all)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    playerData.setCurrentIndex(4)
    testPlayer.playNext()
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()
    testPlayer.setRepeatMode(.single)
    testPlayer.playNext()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertTrue(playerData.isUserQueuePlaying)
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()
  }

  func testPlayer_Play_indexValidation() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
    testPlayer.play()
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_prev_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 1))
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 3))
    checkCurrentlyPlaying(idToBe: 3)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_prev_withWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 1))
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 4))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 3))
    checkCurrentlyPlaying(idToBe: 3)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .prev, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_next_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(3)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 3)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 1))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 3))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [5, 6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_next_withWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(3)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 3)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 1))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 0)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 4))
    checkCurrentlyPlaying(idToBe: 4)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 2))
    checkCurrentlyPlaying(idToBe: 2)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .next, index: 0))
    checkCurrentlyPlaying(idToBe: 1)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_wait_noWaitingQueuePlaying() {
    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(3)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 1))
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 3))
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 2))
    checkCurrentlyPlaying(idToBe: 7)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 5)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [6, 7, 8])
    checkQueueInfoConsistency()

    prepareNoWaitingQueuePlaying()
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()
  }

  func testPlayer_PlayPlayIndex_wait_withWaitingQueuePlaying() {
    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(3)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(2)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 1))
    checkCurrentlyPlaying(idToBe: 7)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(4)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 2))
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 2))
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    testPlayer.removePlayable(at: PlayerIndex(queueType: .user, index: 0))
    playerData.setCurrentIndex(0)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 8)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [0])
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [Int]())
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 0))
    checkCurrentlyPlaying(idToBe: 6)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [7, 8])
    checkQueueInfoConsistency()

    prepareWithWaitingQueuePlaying()
    playerData.setCurrentIndex(-1)
    testPlayer.play(playerIndex: PlayerIndex(queueType: .user, index: 1))
    checkCurrentlyPlaying(idToBe: 7)
    checkQueueItems(queue: testQueueHandler.getAllPrevQueueItems(), seedIds: [Int]())
    checkQueueItems(queue: testQueueHandler.getAllNextQueueItems(), seedIds: [0, 1, 2, 3, 4])
    checkQueueItems(queue: testQueueHandler.getAllUserQueueItems(), seedIds: [8])
    checkQueueInfoConsistency()
  }

  func testSongFinishedPlaying_RepeatSingle() {
    prepareWithAllSongsCached()
    playerData.setCurrentIndex(1)
    testPlayer.play()
    testPlayer.setRepeatMode(.single)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)
  }

  func testSongFinishedPlaying_RepeatAll() {
    prepareWithAllSongsCached()
    playerData.setCurrentIndex(1)
    testPlayer.play()
    testPlayer.setRepeatMode(.all)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[0].id)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)
  }

  func testSongFinishedPlaying_RepeatAll_OneSong() {
    testPlayer.play(context: PlayContext(name: "", playables: [songCached]))

    testPlayer.setRepeatMode(.single)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)

    testPlayer.setRepeatMode(.all)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)

    mockMusicPlayable.expectationDidStartPlaying = expectation(description: "playback started")
    mockMusicPlayable.expectationDidStartPlaying!.expectedFulfillmentCount = 1
    backendPlayer.responder?.didItemFinishedPlaying()
    wait(for: [mockMusicPlayable.expectationDidStartPlaying!], timeout: 2.0)
    XCTAssertTrue(testPlayer.isPlaying)

    testPlayer.setRepeatMode(.off)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertFalse(testPlayer.isPlaying)
  }

  func testSongFinishedPlaying_RepeatOff() {
    prepareWithAllSongsCached()
    playerData.setCurrentIndex(1)
    testPlayer.play()
    testPlayer.setRepeatMode(.off)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertFalse(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)
  }

  func testSongFinishedPlaying_RepeatSingleOffMix() {
    prepareWithAllSongsCached()
    playerData.setCurrentIndex(1)
    testPlayer.play()
    testPlayer.setRepeatMode(.single)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    testPlayer.setRepeatMode(.off)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    testPlayer.setRepeatMode(.single)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    testPlayer.setRepeatMode(.off)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertFalse(testPlayer.isPlaying) // not playing
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)
  }

  func testSongFinishedPlaying_RepeatSingleAllMix() {
    prepareWithAllSongsCached()
    playerData.setCurrentIndex(1)
    testPlayer.play()
    testPlayer.setRepeatMode(.single)
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[1].id)

    testPlayer.setRepeatMode(.all)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[2].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[3].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[0].id)

    testPlayer.setRepeatMode(.single)
    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[0].id)

    backendPlayer.responder?.didItemFinishedPlaying()
    XCTAssertTrue(testPlayer.isPlaying)
    XCTAssertEqual(testPlayer.currentlyPlaying?.id, playlistAllCached.playables[0].id)
  }
}
