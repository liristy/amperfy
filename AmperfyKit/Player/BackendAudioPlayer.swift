//
//  BackendAudioPlayer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.03.19.
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

import AudioStreaming
import AVFoundation
import Foundation
import os.log
import UIKit

// MARK: - BackendAudioPlayerNotifiable

@MainActor
protocol BackendAudioPlayerNotifiable {
  func didElapsedTimeChange()
  func didLyricsTimeChange(time: CMTime) // high refresh count
  func stop()
  func playPrevious()
  func playNext()
  func didItemFinishedPlaying()
  func notifyItemPreparationFinished()
  func notifyErrorOccurred(error: Error)
  func didReadStreamMetadata(_ metadata: [String: String])
}

// MARK: - AudioStreamingPlayer

public class AudioStreamingPlayer: AudioStreaming.AudioPlayer {
  public func elapsedTime() -> Double {
    progress
  }

  public func getState() -> AudioStreaming.AudioPlayerState {
    state
  }
}

// MARK: - PlayType

public enum PlayType {
  case stream
  case cache
}

public typealias CreateAudioStreamingPlayerCallback = () -> AudioStreamingPlayer
public typealias TriggerReinsertPlayableCallback = @MainActor () -> ()
typealias NextPlayablePreloadCallback = () -> AbstractPlayable?

// MARK: - BackendAudioQueueType

enum BackendAudioQueueType {
  case play
  case queue
}

// MARK: - BackendAudioPlayer

@MainActor
class BackendAudioPlayer: NSObject {
  private let getPlayableDownloaderCB: GetPlayableDownloadManagerCallback
  private let cacheProxy: PlayableFileCachable
  private let getBackendApiCB: GetBackendApiCallback
  private let userStatistics: UserStatistics
  private let createAudioStreamingPlayerCB: CreateAudioStreamingPlayerCallback
  private let eventLogger: EventLogger
  private let networkMonitor: NetworkMonitorFacade
  private let updateElapsedTimeInterval = CMTime(
    seconds: 1.0,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let updateLyricsTimeInterval = CMTime(
    seconds: 0.1,
    preferredTimescale: CMTimeScale(NSEC_PER_SEC)
  )
  private let fileManager = CacheFileManager.shared
  private var audioSessionHandler: AudioSessionHandler
  private var isTriggerReinsertPlayableAllowed = true
  private var wasPlayingBeforeErrorOccurred: Bool = false
  private var userDefinedPlaybackRate: PlaybackRate = .one
  private var currentPreparedUrl: String = ""
  private var currentPlayUrl: String = ""
  private var nextPreloadedPlayable: AbstractPlayable?
  private var nextPreloadedUrl: String = ""
  private var advancingAtEndOfItem = false
  private var sourceTask: Task<Void, Never>?
  private var preloadTask: Task<Void, Never>?
  private var volumeRampTask: Task<Void, Never>?
  private var transitionGain: Float = 1 {
    didSet { player?.volume = volumePlayer * transitionGain }
  }
  private var isAutoStartPlayback = true
  private var seekTimeWhenStarted: Double?
  private var lastKnownPlaybackTime: Double = 0

  // Transient recovery is independent of the user's cross-session resume preference.
  var resumePlaybackTime: Double {
    let progress = elapsedTime
    return progress.isFinite && progress > 0 ? progress : lastKnownPlaybackTime
  }
  private var timerElapsedTimeInterval: Timer?
  private var timerLyricsTimeInterval: Timer?
  private var isVisualUpdatesEnabled = true
  private var volumePlayer: Float = 1.0

  private var player: AudioStreamingPlayer?
  private var equalizer: AVAudioUnitEQ?
  private var replayGainNode: AVAudioMixerNode?
  public private(set) var audioAnalyzer: AudioAnalyzer

  // ReplayGain Settings
  private var isReplayGainEnabled: Bool = true
  private var currentReplayGainValue: Float = 0.0 // ReplayGain in dB
  // EQ Settings
  private var equalizerVolumeCompensation: Float = 1.0
  private var isEqualizerEnabled: Bool = true
  private var currentEqualizerSetting: EqualizerSetting = .off

  public var isOfflineMode: Bool = false
  public var isAutoCachePlayedItems: Bool = true
  public var nextPlayablePreloadCB: NextPlayablePreloadCallback?
  public var triggerReinsertPlayableCB: TriggerReinsertPlayableCallback?
  public private(set) var isPlaying: Bool = false
  public private(set) var isErrorOccurred: Bool = false
  public private(set) var playType: PlayType?
  private var perloadedPlayType: PlayType?
  public private(set) var activeStreamingBitrate: StreamingMaxBitratePreference?
  private var perloadedStreamingBitrate: StreamingMaxBitratePreference?
  public private(set) var activeTranscodingFormat: StreamingFormatPreference?
  private var preloadTranscodingFormat: StreamingFormatPreference?
  public private(set) var streamingMaxBitrates = StreamingMaxBitrates()
  public func setStreamingMaxBitrates(to: StreamingMaxBitrates) {
    let oldBitrate = streamingMaxBitrates.getActive(networkMonitor: networkMonitor)
    let newBitrate = to.getActive(networkMonitor: networkMonitor)

    os_log(
      .default,
      "Update Streaming Max Bitrate: %s -> %s (for next stream)",
      oldBitrate.description,
      newBitrate.description
    )
    // Update the stored bitrates
    streamingMaxBitrates = to
  }

  public private(set) var streamingTranscodings = StreamingTranscodings()
  public func setStreamingTranscodings(to: StreamingTranscodings) {
    os_log(
      .default,
      "Update Streaming Transcoding: <Wifi: %s, Cellular: %s> -> <Wifi: %s, Cellular: %s> (for next stream)",
      streamingTranscodings.wifi.description,
      streamingTranscodings.cellular.description,
      to.wifi.description,
      to.cellular.description
    )
    // Update the stored bitrates
    streamingTranscodings = to
  }

  var responder: BackendAudioPlayerNotifiable?
  var volume: Float {
    get {
      volumePlayer
    }
    set {
      volumePlayer = newValue
      player?.volume = newValue * transitionGain
    }
  }

  var isStopped: Bool {
    playType == nil
  }

  var elapsedTime: Double {
    // The engine may still be rendering the tail of the previous selection.
    currentPlayUrl.isEmpty ? (seekTimeWhenStarted ?? 0) : (player?.elapsedTime() ?? 0)
  }

  var duration: Double {
    currentPlayUrl.isEmpty ? 0 : (player?.duration ?? 0)
  }

  var playbackRate: PlaybackRate {
    userDefinedPlaybackRate
  }

  var canBeContinued: Bool {
    currentPlayUrl != "" &&
      (
        player?.getState() == .paused || player?.getState() == .playing || player?
          .getState() == .bufferring
      )
  }

  init(
    createAudioStreamingPlayerCB: @escaping CreateAudioStreamingPlayerCallback,
    audioSessionHandler: AudioSessionHandler,
    eventLogger: EventLogger,
    getBackendApiCB: @escaping GetBackendApiCallback,
    networkMonitor: NetworkMonitorFacade,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback,
    cacheProxy: PlayableFileCachable,
    userStatistics: UserStatistics,
    visualUpdatesEnabled: Bool = true
  ) {
    self.createAudioStreamingPlayerCB = createAudioStreamingPlayerCB
    self.audioSessionHandler = audioSessionHandler
    self.getBackendApiCB = getBackendApiCB
    self.networkMonitor = networkMonitor
    self.eventLogger = eventLogger
    self.getPlayableDownloaderCB = getPlayableDownloaderCB
    self.cacheProxy = cacheProxy
    self.userStatistics = userStatistics
    self.audioAnalyzer = AudioAnalyzer()

    super.init()

    isVisualUpdatesEnabled = visualUpdatesEnabled
    audioAnalyzer.isInForeground = isVisualUpdatesEnabled
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil
    )
    initAudioStreamingPlayerAndNodes()
  }

  @objc private func applicationDidEnterBackground() {
    setVisualUpdatesEnabled(false)
  }

  @objc private func applicationDidBecomeActive() {
    setVisualUpdatesEnabled(true)
  }

  func setVisualUpdatesEnabled(_ enabled: Bool) {
    guard isVisualUpdatesEnabled != enabled else { return }
    isVisualUpdatesEnabled = enabled
    audioAnalyzer.isInForeground = enabled
    stopLyricsTimer()
    if enabled {
      // Refresh once even when paused: the playhead may have changed while
      // the app was hidden. Only playing starts the high-frequency timer.
      notifyLyricsTimeChanged()
      startLyricsTimerIfNeeded()
    }
  }

  private func notifyLyricsTimeChanged() {
    let seconds = elapsedTime
    guard seconds.isFinite, seconds >= 0 else { return }
    responder?.didLyricsTimeChange(time: CMTime(seconds: seconds, preferredTimescale: 1_000))
  }

  private func startTimers() {
    stopTimers()
    timerElapsedTimeInterval = Timer.scheduledTimer(
      withTimeInterval: updateElapsedTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        guard let self = self else { return }
        if self.elapsedTime.isFinite, self.elapsedTime > 0 {
          if self.elapsedTime > self.lastKnownPlaybackTime {
            // A healthy engine can recover from a later, independent interruption.
            self.isTriggerReinsertPlayableAllowed = true
          }
          self.lastKnownPlaybackTime = self.elapsedTime
        }
        self.checkForPreloadNextPlayerItem()
        self.responder?.didElapsedTimeChange()
      }
    }
    // Keep playback bookkeeping, preload and lock-screen updates at 1 Hz.
    timerElapsedTimeInterval?.tolerance = 0.1
    startLyricsTimerIfNeeded()
  }

  private func startLyricsTimerIfNeeded() {
    guard isPlaying, isVisualUpdatesEnabled, timerLyricsTimeInterval == nil else { return }
    timerLyricsTimeInterval = Timer(
      timeInterval: updateLyricsTimeInterval.seconds,
      repeats: true
    ) { [weak self] timer in
      Task { @MainActor in
        // A callback queued before backgrounding or pausing must not refresh UI.
        guard let self, self.isPlaying, self.isVisualUpdatesEnabled else { return }
        self.notifyLyricsTimeChanged()
      }
    }
    // Keep synchronized highlighting alive while a scroll view is tracking touches.
    if let timerLyricsTimeInterval {
      RunLoop.main.add(timerLyricsTimeInterval, forMode: .common)
    }
  }

  private func stopTimers() {
    timerElapsedTimeInterval?.invalidate()
    timerElapsedTimeInterval = nil
    stopLyricsTimer()
  }

  private func stopLyricsTimer() {
    timerLyricsTimeInterval?.invalidate()
    timerLyricsTimeInterval = nil
  }

  private func checkForPreloadNextPlayerItem() {
    guard isAutoStartPlayback, !currentPlayUrl.isEmpty else { return }
    if nextPreloadedPlayable == nil, elapsedTime.isFinite, elapsedTime > 0, duration.isFinite,
       duration > 0 {
      let remainingTime = duration - elapsedTime
      if remainingTime > 0, remainingTime < 10 {
        nextPreloadedPlayable = nextPlayablePreloadCB?()
        guard let nextPreloadedPlayable = nextPreloadedPlayable else { return }
        os_log(.default, "Preloading: %s", nextPreloadedPlayable.displayString)
        if nextPreloadedPlayable.isCached {
          insertCachedPlayable(playable: nextPreloadedPlayable, queueType: .queue)
        } else if !isOfflineMode {
          preloadTask = Task { @MainActor in
            do {
              try await insertStreamPlayable(playable: nextPreloadedPlayable, queueType: .queue)
              guard !Task.isCancelled else { return }
              if self.isAutoCachePlayedItems, nextPreloadedPlayable.isDownloadAvailable,
                 let accountInfo = nextPreloadedPlayable.account?.info {
                self.getPlayableDownloaderCB(accountInfo).download(object: nextPreloadedPlayable)
              }
            } catch {
              guard !Task.isCancelled else { return }
              self.nextPreloadedPlayable = nil
              self.eventLogger.report(topic: "Player", error: error)
            }
          }
        }
      }
    }
  }

  @MainActor
  private func itemFinishedPlaying() {
    isTriggerReinsertPlayableAllowed = true
    if nextPreloadedPlayable != nil {
      isPlaying = true
      startTimers()
    } else {
      isPlaying = false
      stopTimers()
    }
    advancingAtEndOfItem = true
    defer { advancingAtEndOfItem = false }
    responder?.didItemFinishedPlaying()
  }

  private func handleError(error: Error) {
    isErrorOccurred = true
    wasPlayingBeforeErrorOccurred = isPlaying
    pause(preservingRecoveryPlayback: true)
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    cancelPendingSourceChange()
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    restartPlayer()
    eventLogger.report(topic: "Player Status", error: error)
    responder?.notifyErrorOccurred(error: error)
    if isTriggerReinsertPlayableAllowed {
      isTriggerReinsertPlayableAllowed = false
      triggerReinsertPlayableCB?()
    }
  }

  func continuePlay() {
    isAutoStartPlayback = true
    isPlaying = true
    player?.resume()
    fadeInWhenPlaying()
    startTimers()
    player?.rate = Float(userDefinedPlaybackRate.asDouble)
    audioAnalyzer.play()
  }

  func pause(preservingRecoveryPlayback: Bool = false) {
    // A delayed engine-start callback must honor a pause requested while the
    // cached file or stream is still being prepared.
    isAutoStartPlayback = false
    if !preservingRecoveryPlayback { wasPlayingBeforeErrorOccurred = false }
    lastKnownPlaybackTime = resumePlaybackTime
    isPlaying = false
    player?.pause()
    if !currentPlayUrl.isEmpty {
      volumeRampTask?.cancel()
      volumeRampTask = nil
    }
    stopTimers()
    audioAnalyzer.stop()
  }

  func stop() {
    isPlaying = false
    clearPlayer()
    audioAnalyzer.stop()
  }

  func setPlaybackRate(_ newValue: PlaybackRate) {
    userDefinedPlaybackRate = newValue
    player?.rate = Float(newValue.asDouble)
  }

  func seek(toSecond: Double) {
    guard toSecond.isFinite, toSecond >= 0 else { return }
    lastKnownPlaybackTime = toSecond
    if currentPlayUrl != "", player?.getState() == .playing || player?.getState() == .paused {
      seekTimeWhenStarted = nil
      player?.seek(to: toSecond)
    } else {
      seekTimeWhenStarted = toSecond
    }
  }

  private func restartPlayer() {
    player?.delegate = nil
    player = nil
    initAudioStreamingPlayerAndNodes()
  }

  private func initAudioStreamingPlayerAndNodes() {
    guard player == nil else { return }
    player = createAudioStreamingPlayerCB()

    equalizer = AVAudioUnitEQ(numberOfBands: 10)
    replayGainNode = AVAudioMixerNode()
    audioAnalyzer = AudioAnalyzer()

    guard let player,
          let eq = equalizer,
          let replayGain = replayGainNode
    else { return }

    player.volume = volumePlayer * transitionGain
    player.delegate = self

    player.attach(nodes: [eq, replayGain])

    audioAnalyzer.install(on: equalizer!)

    setupEqualizerBands()
    applyEqualizerSetting(eqSetting: currentEqualizerSetting)
    applyReplayGain()
    os_log(.debug, "Player setup completed with EQ and ReplayGain support")
  }

  var shouldPlaybackStart: Bool {
    (!isErrorOccurred && isAutoStartPlayback) || (isErrorOccurred && wasPlayingBeforeErrorOccurred)
  }

  func requestToPlay(
    playable: AbstractPlayable,
    playbackRate: PlaybackRate,
    autoStartPlayback: Bool
  ) {
    cancelPendingSourceChange()
    currentPreparedUrl = ""
    currentPlayUrl = ""
    userDefinedPlaybackRate = playbackRate
    lastKnownPlaybackTime = 0
    seekTimeWhenStarted = nil
    isAutoStartPlayback = autoStartPlayback
    handleRequest(playable: playable)
  }

  private func handleRequest(playable: AbstractPlayable) {
    if advancingAtEndOfItem, !nextPreloadedUrl.isEmpty, let nextPreloadedPlayable = nextPreloadedPlayable,
       nextPreloadedPlayable == playable {
      // Do nothing next preloaded playable has already been queued to player
      os_log(.default, "Play Preloaded: %s", nextPreloadedPlayable.displayString)
      currentPlayUrl = nextPreloadedUrl
      playType = perloadedPlayType
      perloadedPlayType = nil
      activeStreamingBitrate = perloadedStreamingBitrate
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = preloadTranscodingFormat
      preloadTranscodingFormat = nil
      player?.rate = Float(userDefinedPlaybackRate.asDouble)
      currentReplayGainValue = nextPreloadedPlayable.replayGainTrackGain
      applyReplayGain()
      fadeInWhenPlaying()
      self.nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      responder?.notifyItemPreparationFinished()
    } else if let relFilePath = playable.relFilePath,
              fileManager.fileExits(relFilePath: relFilePath) {
      nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      insertCachedPlayable(playable: playable)
      isPlaying = shouldPlaybackStart
      responder?.notifyItemPreparationFinished()
    } else if !isOfflineMode {
      nextPreloadedPlayable = nil
      nextPreloadedUrl = ""
      activeStreamingBitrate = nil
      perloadedStreamingBitrate = nil
      activeTranscodingFormat = nil
      preloadTranscodingFormat = nil
      guard playable.isPlayableOniOS else {
        reactToIncompatibleContentType(
          contentType: playable.fileContentType ?? "",
          playableDisplayTitle: playable.displayString
        )
        return
      }
      if let radio = playable.asRadio {
        // radios must have a valid URL
        guard let urlString = radio.url,
              URL(string: urlString) != nil
        else {
          reactToInvalidRadioUrl(playableDisplayTitle: playable.displayString)
          return
        }
      }

      sourceTask = Task { @MainActor in
        do {
          try await insertStreamPlayable(playable: playable)
          guard !Task.isCancelled else { return }
          isPlaying = shouldPlaybackStart
          if self.isAutoCachePlayedItems, !playable.isRadio,
             let accountInfo = playable.account?.info {
            self.getPlayableDownloaderCB(accountInfo).download(object: playable)
          }
          self.responder?.notifyItemPreparationFinished()
        } catch {
          guard !Task.isCancelled else { return }
          clearPlayer()
          self.responder?.notifyErrorOccurred(error: error)
          self.responder?.notifyItemPreparationFinished()
          self.eventLogger.report(topic: "Player", error: error)
        }
      }
    } else {
      clearPlayer()
      responder?.notifyItemPreparationFinished()
    }
  }

  private func reactToIncompatibleContentType(contentType: String, playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "Content type \"\(contentType)\" of \"\(playableDisplayTitle)\" is not playable via Amperfy.",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func reactToInvalidRadioUrl(playableDisplayTitle: String) {
    clearPlayer()
    eventLogger.info(
      topic: "Player Info",
      statusCode: .playerError,
      message: "Radio \"\(playableDisplayTitle)\" has an invalid stream URL.",
      displayPopup: true
    )
    responder?.notifyItemPreparationFinished()
  }

  private func clearPlayer() {
    cancelPendingSourceChange()
    lastKnownPlaybackTime = 0
    currentPreparedUrl = ""
    currentPlayUrl = ""
    nextPreloadedPlayable = nil
    nextPreloadedUrl = ""
    playType = nil
    perloadedPlayType = nil
    activeStreamingBitrate = nil
    perloadedStreamingBitrate = nil
    activeTranscodingFormat = nil
    preloadTranscodingFormat = nil
    seekTimeWhenStarted = nil
    isPlaying = false
    playType = nil

    stopTimers()
    audioAnalyzer.stop()
    player?.stop()
    transitionGain = 1
  }

  private func insertCachedPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) {
    guard let fileURL = cacheProxy.getFileURL(forPlayable: playable) else {
      return
    }
    if queueType == .play {
      playType = .cache
      perloadedPlayType = nil
      os_log(.default, "Play Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    } else {
      perloadedPlayType = .cache
      os_log(.default, "Insert Cache: %s (%s)", playable.displayString, fileURL.absoluteString)
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: true) }
    insert(playable: playable, withUrl: fileURL, queueType: queueType)
  }

  @MainActor
  private func insertStreamPlayable(
    playable: AbstractPlayable,
    queueType: BackendAudioQueueType = .play
  ) async throws {
    try Task.checkCancellation()
    let streamingMaxBitrate: StreamingMaxBitratePreference = .noLimit
    let streamingTranscodingFormat: StreamingFormatPreference = .raw
    var httpHeaders: [String: String] = [:]
    let streamUrl: URL
    if let radio = playable.asRadio {
      guard let address = radio.url, let url = URL(string: address) else { throw BackendError.invalidUrl }
      streamUrl = url
    } else {
      guard let accountInfo = playable.account?.info else { throw BackendError.noCredentials }
      let backendApi = getBackendApiCB(accountInfo)
      httpHeaders = backendApi.httpHeaders
      streamUrl = try await backendApi.generateUrl(
        forStreamingPlayable: playable.info, maxBitrate: streamingMaxBitrate,
        formatPreference: streamingTranscodingFormat
      )
    }
    try Task.checkCancellation()

    if queueType == .play {
      playType = .stream
      activeStreamingBitrate = playable.isRadio ? nil : streamingMaxBitrate
      activeTranscodingFormat = playable.isRadio ? nil : streamingTranscodingFormat
      os_log(
        .default,
        "Play Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    } else {
      perloadedPlayType = .stream
      perloadedStreamingBitrate = playable.isRadio ? nil : streamingMaxBitrate
      preloadTranscodingFormat = playable.isRadio ? nil : streamingTranscodingFormat
      os_log(
        .default,
        "Insert Stream: %s (%s)",
        playable.displayString,
        streamingMaxBitrate.description
      )
    }
    if playable.isSong { userStatistics.playedSong(isPlayedFromCache: false) }
    insert(
      playable: playable,
      withUrl: streamUrl,
      queueType: queueType,
      httpHeaders: httpHeaders
    )
  }

  private func insert(
    playable: AbstractPlayable,
    withUrl url: URL,
    queueType: BackendAudioQueueType,
    httpHeaders: [String: String] = [:]
  ) {
    if queueType == .queue {
      nextPreloadedUrl = url.absoluteString
      if httpHeaders.isEmpty {
        player?.queue(url: url)
      } else {
        player?.queue(url: url, headers: httpHeaders)
      }
      return
    }

    @MainActor func replaceSource() {
      // play(url:) replaces the decoder and its buffers. Pausing here would
      // also reset the audio engine and stop the output hardware on every skip.
      transitionGain = 0
      currentReplayGainValue = playable.replayGainTrackGain
      applyReplayGain()
      player?.rate = Float(userDefinedPlaybackRate.asDouble)
      if player?.getState() != .playing {
        audioSessionHandler.configureBackgroundPlayback()
      }
      currentPreparedUrl = url.absoluteString
      if httpHeaders.isEmpty {
        player?.play(url: url)
      } else {
        player?.play(url: url, headers: httpHeaders)
      }
    }

    guard player?.getState() == .playing, transitionGain > 0 else {
      replaceSource()
      return
    }
    volumeRampTask = Task { @MainActor in
      do {
        try await rampOutput(to: 0)
        // Let the output render the final muted buffer before changing track gain.
        try await Task.sleep(for: .seconds(AVAudioSession.sharedInstance().ioBufferDuration))
      } catch { return }
      guard !Task.isCancelled else { return }
      volumeRampTask = nil
      replaceSource()
    }
  }

  private func cancelPendingSourceChange() {
    sourceTask?.cancel()
    sourceTask = nil
    preloadTask?.cancel()
    preloadTask = nil
    volumeRampTask?.cancel()
    volumeRampTask = nil
  }

  private func rampOutput(to target: Float) async throws {
    let start = transitionGain
    for step in 1...12 {
      try await Task.sleep(for: .milliseconds(2))
      try Task.checkCancellation()
      transitionGain = start + (target - start) * (Float(step) / 12)
    }
  }

  private func fadeInWhenPlaying() {
    // didStartPlaying identifies the entry, but can precede its first decoded
    // buffer. Wait for both the matching entry and actual rendering.
    guard isPlaying, !currentPlayUrl.isEmpty, player?.getState() == .playing,
          transitionGain < 1, volumeRampTask == nil else { return }
    volumeRampTask = Task { @MainActor in
      do { try await rampOutput(to: 1) } catch { return }
      guard !Task.isCancelled else { return }
      volumeRampTask = nil
    }
  }

  // MARK: - EQ Implementation

  func updateEqualizerEnabled(isEnabled: Bool) {
    isEqualizerEnabled = isEnabled
    os_log(.debug, "Equalizer enabled: %s", isEnabled.description)
    applyEqualizerToActiveContent()
  }

  func updateEqualizerSetting(eqSetting: EqualizerSetting) {
    let oldSetting = currentEqualizerSetting
    currentEqualizerSetting = eqSetting
    os_log(
      .debug,
      "Equalizer changed from %s to %s",
      oldSetting.description,
      eqSetting.description
    )
    applyEqualizerToActiveContent()
  }

  private func applyEqualizerToActiveContent() {
    if isEqualizerEnabled {
      applyEqualizerSetting(eqSetting: currentEqualizerSetting)
    } else {
      applyEqualizerSetting(eqSetting: .off)
    }
    applyReplayGain()
  }

  private func setupEqualizerBands() {
    guard let equalizer else { return }

    for (index, frequency) in EqualizerSetting.frequencies.enumerated() {
      guard index < equalizer.bands.count else { break }

      let band = equalizer.bands[index]
      band.frequency = frequency
      band.bandwidth = 1.0
      band.filterType = .parametric
      band.gain = 0.0
      band.bypass = false
    }
  }

  private func applyEqualizerSetting(eqSetting: EqualizerSetting) {
    guard let equalizer else { return }

    // EQ band gains
    for (index, gain) in eqSetting.gains.enumerated() {
      guard index < equalizer.bands.count else { break }

      let band = equalizer.bands[index]

      band.filterType = .parametric
      band.bandwidth = 1.0
      band.gain = gain
      band.bypass = false
    }

    equalizerVolumeCompensation = isEqualizerEnabled ? eqSetting.compensatedVolume : 1.0

    os_log(.debug, "   EQ '%s'", eqSetting.description)
    os_log(
      .debug,
      "   EQ Gains: [%@] dB",
      eqSetting.gains.map { String(format: "%.1f", $0) }.joined(separator: ", ")
    )
    os_log(.debug, "   EQ Gain Compensation: %.1f dB", eqSetting.gainCompensation)
    os_log(.debug, "   EQ linear Volume Compensation: %.2f", eqSetting.compensatedVolume)
    os_log(.debug, "   Active EQ linear Volume Compensation: %.2f", equalizerVolumeCompensation)
  }

  // MARK: - ReplayGain Implementation

  func updateReplayGainEnabled(isEnabled: Bool) {
    isReplayGainEnabled = isEnabled
    applyReplayGain()
  }

  private func applyReplayGain() {
    guard let replayGain = replayGainNode else { return }

    let eqCompensation = isEqualizerEnabled ? equalizerVolumeCompensation : 1.0

    if isReplayGainEnabled, currentReplayGainValue != 0.0 {
      // Convert dB to linear scale: gain = pow(10, dB / 20)
      let linearGain = pow(10.0, currentReplayGainValue / 20.0)
      replayGain.outputVolume = linearGain * eqCompensation
      os_log(
        .debug,
        "ReplayGain: %.2f dB → %.3f linear gain (EQ Compensation: %.2f)",
        currentReplayGainValue,
        linearGain,
        eqCompensation
      )
    } else {
      replayGain.outputVolume = eqCompensation
      os_log(
        .debug,
        "ReplayGain: disabled or no gain data (EQ Compensation: %.2f)",
        eqCompensation
      )
    }
  }
}

// MARK: AudioStreaming.AudioPlayerDelegate

extension BackendAudioPlayer: AudioStreaming.AudioPlayerDelegate {
  nonisolated func audioPlayerDidStartPlaying(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {
    let entryID = entryId.id
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      didStartPlaying(url: entryID)
    }
  }

  @MainActor
  public func didStartPlaying(url: String) {
    if currentPreparedUrl == url {
      if let sampleRate = player?.mainMixerNode.outputFormat(forBus: 0).sampleRate {
        audioAnalyzer.playing(sampleRate: Float(sampleRate))
      }

      currentPreparedUrl = ""
      currentPlayUrl = url
      if shouldPlaybackStart {
        continuePlay()
        audioAnalyzer.play()
      } else {
        pause()
        audioAnalyzer.stop()
      }

      if let seekTimeWhenStarted {
        player?.seek(to: seekTimeWhenStarted)
        self.seekTimeWhenStarted = nil
      }
      isErrorOccurred = false
    }
  }

  nonisolated func audioPlayerDidFinishBuffering(
    player: AudioStreaming.AudioPlayer,
    with entryId: AudioStreaming.AudioEntryId
  ) {}

  nonisolated func audioPlayerStateChanged(
    player: AudioStreaming.AudioPlayer,
    with newState: AudioStreaming.AudioPlayerState,
    previous: AudioStreaming.AudioPlayerState
  ) {
    guard newState == .playing else { return }
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      fadeInWhenPlaying()
    }
  }

  nonisolated func audioPlayerDidFinishPlaying(
    player: AudioStreaming.AudioPlayer,
    entryId: AudioStreaming.AudioEntryId,
    stopReason: AudioStreaming.AudioPlayerStopReason,
    progress: Double,
    duration: Double
  ) {
    // Gapless queue transitions leave the engine running, so the library reports
    // .none. Only an empty queue produces .eof; explicit stops must not advance it.
    guard stopReason == .eof || stopReason == .none else { return }
    let entryID = entryId.id
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      if self.currentPlayUrl == entryID {
        self.currentPlayUrl = ""
        self.itemFinishedPlaying()
      }
    }
  }

  nonisolated func audioPlayerUnexpectedError(
    player: AudioStreaming.AudioPlayer,
    error: AudioStreaming.AudioPlayerError
  ) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      self.handleError(error: error)
    }
  }

  nonisolated func audioPlayerDidCancel(
    player: AudioStreaming.AudioPlayer,
    queuedItems: [AudioStreaming.AudioEntryId]
  ) {
    // The library cancels pending queue entries, not the currently playing item.
    // Clearing currentPlayUrl here made the next resume restart the current song.
    let cancelledIDs = queuedItems.map(\.id)
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      if cancelledIDs.contains(self.nextPreloadedUrl) {
        self.nextPreloadedPlayable = nil
        self.nextPreloadedUrl = ""
      }
    }
  }

  nonisolated func audioPlayerDidReadMetadata(
    player: AudioStreaming.AudioPlayer,
    metadata: [String: String]
  ) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.player.map(ObjectIdentifier.init) == identity else { return }
      self.responder?.didReadStreamMetadata(metadata)
    }
  }
}
