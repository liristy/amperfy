//
//  AudioPlayer.swift
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

import AVFoundation
import CoreData
import Foundation
import MediaPlayer
import os.log

// MARK: - WeakMusicPlayable

final class WeakMusicPlayable {
  weak var value: MusicPlayable?
  init(_ value: MusicPlayable) {
    self.value = value
  }
}

// MARK: - AudioPlayer

@MainActor
public class AudioPlayer: NSObject, BackendAudioPlayerNotifiable {
  public static let replayInsteadPlayPreviousTimeInSec = 5.0
  static let progressTimeStartThreshold: Double = 15.0
  static let progressTimeEndThreshold: Double = 15.0

  var currentlyPlaying: AbstractPlayable? {
    queueHandler.currentlyPlaying
  }

  var currentMusicItem: AbstractPlayable? {
    queueHandler.currentMusicItem
  }

  var currentPodcastItem: AbstractPlayable? {
    queueHandler.currentPodcastItem
  }

  var isShouldPauseAfterFinishedPlaying = false
  var autoplayCB: (@MainActor (Song, Set<NSManagedObjectID>, Set<NSManagedObjectID>) async throws -> [Song])?
  private var autoplayTask: Task<Void, Never>?
  private var autoplayRequestID: UUID?
  private var awaitingAutoplayAdvance = false
  private var preparedAutoplaySongs: [Song] = []
  private var autoplayPreparedForSeed: NSManagedObjectID?
  private var recentAutoplayItems: [NSManagedObjectID] = []

  private var canAutoplay: Bool {
    settings.user.isAutoplayEnabled && playerStatus.playerMode == .music &&
      playerStatus.repeatMode == .off && currentlyPlaying?.asSong != nil
  }

  var autoplayQueue: [Song] { canAutoplay ? preparedAutoplaySongs : [] }

  private var autoplayExcludedItems: Set<NSManagedObjectID> {
    var items = queueHandler.getAllNextQueueItems() + queueHandler.getAllUserQueueItems()
    if let currentlyPlaying { items.append(currentlyPlaying) }
    return Set(items.compactMap { $0.asSong?.managedObject.objectID })
  }

  private func cancelAutoplayRequest(clearQueue: Bool = false) {
    autoplayRequestID = nil
    autoplayTask?.cancel()
    autoplayTask = nil
    awaitingAutoplayAdvance = false
    if clearQueue {
      preparedAutoplaySongs.removeAll()
      autoplayPreparedForSeed = nil
    }
  }

  func autoplaySettingDidChange() {
    cancelAutoplayRequest(clearQueue: true)
    prepareAutoplayIfNeeded()
    notifyPlaylistUpdated()
  }

  func setAutoplayEnabled(_ enabled: Bool) {
    settings.user.isAutoplayEnabled = enabled
    autoplaySettingDidChange()
  }

  // Prepare recommendations before the explicit queue runs out. They stay separate
  // from that queue so disabling Autoplay never removes a user's queued songs.
  func prepareAutoplayIfNeeded() {
    guard canAutoplay else {
      cancelAutoplayRequest(clearQueue: true)
      return
    }
    let explicitQueueCount = queueHandler.nextQueueCount + queueHandler.userQueueCount
    if explicitQueueCount > 3, preparedAutoplaySongs.isEmpty { return }
    let excluded = autoplayExcludedItems
    preparedAutoplaySongs.removeAll {
      excluded.contains($0.managedObject.objectID) || (backendAudioPlayer.isOfflineMode && !$0.isCached)
    }
    guard preparedAutoplaySongs.count < 5, autoplayTask == nil,
          explicitQueueCount <= 3,
          let currentSong = currentlyPlaying?.asSong, let cb = autoplayCB else { return }
    let seed = queueHandler.getAllNextQueueItems().last?.asSong ??
      queueHandler.getAllUserQueueItems().last?.asSong ?? currentSong
    guard preparedAutoplaySongs.isEmpty || autoplayPreparedForSeed != seed.managedObject.objectID else { return }
    let currentID = currentSong.managedObject.objectID
    let requestID = UUID()
    autoplayRequestID = requestID
    let recent = Set(recentAutoplayItems.suffix(20))
    let requestExcluded = excluded.union(preparedAutoplaySongs.map { $0.managedObject.objectID })
    autoplayTask = Task { @MainActor [weak self] in
      do {
        guard !Task.isCancelled else { return }
        let songs = try await cb(seed, requestExcluded, recent)
        guard let self, !Task.isCancelled, autoplayRequestID == requestID else { return }
        autoplayTask = nil
        autoplayRequestID = nil
        guard canAutoplay, currentlyPlaying?.asSong?.managedObject.objectID == currentID else {
          awaitingAutoplayAdvance = false
          return
        }
        var seen = autoplayExcludedItems.union(preparedAutoplaySongs.map { $0.managedObject.objectID })
        let candidates = songs.filter {
          $0.account == currentSong.account &&
            (!backendAudioPlayer.isOfflineMode || $0.isCached) &&
            seen.insert($0.managedObject.objectID).inserted
        }
        preparedAutoplaySongs.append(contentsOf: candidates.prefix(20))
        autoplayPreparedForSeed = seed.managedObject.objectID
        let shouldAdvance = awaitingAutoplayAdvance
        awaitingAutoplayAdvance = false
        notifyPlaylistUpdated()
        if shouldAdvance {
          if let nextPlayerIndex { play(playerIndex: nextPlayerIndex) }
          else if preparedAutoplaySongs.isEmpty { pause() }
          else { playAutoplay(at: 0) }
        }
      } catch {
        guard let self, autoplayRequestID == requestID else { return }
        autoplayTask = nil
        autoplayRequestID = nil
        let shouldPause = awaitingAutoplayAdvance
        awaitingAutoplayAdvance = false
        if shouldPause { pause() }
      }
    }
  }

  func playAutoplay(at index: Int) {
    guard canAutoplay, preparedAutoplaySongs.indices.contains(index) else { return }
    let song = preparedAutoplaySongs[index]
    preparedAutoplaySongs.removeFirst(index + 1)
    queueHandler.appendContextQueue(playables: [song])
    play(playerIndex: PlayerIndex(queueType: .next, index: queueHandler.nextQueueCount - 1))
    notifyPlaylistUpdated()
  }

  private var playerStatus: PlayerStatusPersistent
  private var queueHandler: PlayQueueHandler
  private let backendAudioPlayer: BackendAudioPlayer
  private let settings: AmperfySettings
  private let userStatistics: UserStatistics
  private var notifierList: [WeakMusicPlayable] = []
  public private(set) var currentRadioNowPlaying: RadioNowPlayingInfo?
  private var lastRadioStreamTitle: String?
  private var pendingResumeTime: Double?
  var isPlaying: Bool { backendAudioPlayer.isPlaying }

  init(
    coreData: PlayerStatusPersistent,
    queueHandler: PlayQueueHandler,
    backendAudioPlayer: BackendAudioPlayer,
    settings: AmperfySettings,
    userStatistics: UserStatistics
  ) {
    self.playerStatus = coreData
    self.queueHandler = queueHandler
    self.backendAudioPlayer = backendAudioPlayer
    self.backendAudioPlayer.isAutoCachePlayedItems = coreData.isAutoCachePlayedItems
    self.settings = settings
    self.userStatistics = userStatistics
    super.init()
    self.backendAudioPlayer.responder = self
    self.backendAudioPlayer.nextPlayablePreloadCB = { () in
      guard !self.isShouldPauseAfterFinishedPlaying else { return nil }
      guard self.playerStatus.repeatMode != .single else { return nil }
      guard let nextPlayerIndex = self.nextPlayerIndex else { return nil }
      return self.queueHandler.getPlayable(at: nextPlayerIndex)
    }
  }

  private func shouldCurrentItemReplayedInsteadOfPrevious() -> Bool {
    if let currentlyPlaying = currentlyPlaying,
       currentlyPlaying.isRadio {
      return false
    }
    if !backendAudioPlayer.canBeContinued {
      return false
    }
    return backendAudioPlayer.elapsedTime >= Self.replayInsteadPlayPreviousTimeInSec
  }

  private func replayCurrentItem() {
    os_log(.debug, "Replay")
    if let currentPlayable = currentlyPlaying {
      insertIntoPlayer(playable: currentPlayable)
    }
    notifyItemStartedPlayingFromBeginning()
  }

  private func insertIntoPlayer(playable: AbstractPlayable, resumeTime: Double? = nil) {
    cancelAutoplayRequest()
    if let song = playable.asSong {
      recentAutoplayItems.append(song.managedObject.objectID)
      if recentAutoplayItems.count > 20 { recentAutoplayItems.removeFirst() }
    }
    pendingResumeTime = resumeTime
    if resumeTime == nil {
      userStatistics.playedItem(
        repeatMode: playerStatus.repeatMode,
        isShuffle: playerStatus.isShuffle
      )
      playable.countPlayed()
    }
    backendAudioPlayer.requestToPlay(
      playable: playable,
      playbackRate: playerStatus.playbackRate,
      autoStartPlayback: !settings.user.isPlaybackStartOnlyOnPlay
    )
  }

  // BackendAudioPlayerNotifiable
  func notifyItemPreparationFinished() {
    handleRadioStartIfNeeded()
    notifyItemStartedPlayingFromBeginning()
    notifyItemStartedPlaying()
    prepareAutoplayIfNeeded()
  }

  // BackendAudioPlayerNotifiable
  func didItemFinishedPlaying() {
    if isShouldPauseAfterFinishedPlaying {
      isShouldPauseAfterFinishedPlaying = false
      pause()
    } else if playerStatus
      .repeatMode == .single ||
      (
        // repeat mode all and only one song is in player -> repeat
        playerStatus.repeatMode == .all && queueHandler.prevQueueCount == 0 && queueHandler
          .userQueueCount == 0 && queueHandler
          .nextQueueCount == 0
      ) {
      replayCurrentItem()
    } else if !settings.user.isPlaybackStartOnlyOnPlay {
      playNext()
    }
  }

  func play() {
    if !backendAudioPlayer.canBeContinued {
      if let currentPlayable = currentlyPlaying {
        let resumeTime = !currentPlayable.isRadio && !backendAudioPlayer.isStopped ?
          backendAudioPlayer.resumePlaybackTime : nil
        insertIntoPlayer(playable: currentPlayable, resumeTime: resumeTime)
      }
    } else {
      backendAudioPlayer.continuePlay()
      notifyItemStartedPlaying()
    }
    prepareAutoplayIfNeeded()
  }

  public func play(context: PlayContext) {
    guard let activePlayable = context.getActivePlayable() else { return }
    cancelAutoplayRequest(clearQueue: true)
    recentAutoplayItems.removeAll()
    let topUserQueueItem = queueHandler.getUserQueueItem(at: 0)
    let wasUserQueuePlaying = queueHandler.isUserQueuePlaying
    queueHandler.clearActiveQueue()
    queueHandler.appendActiveQueue(playables: context.playables)
    if context.type == .music {
      queueHandler.setContextName(context.name)
    }

    if queueHandler.isUserQueuePlaying {
      play(playerIndex: PlayerIndex(queueType: .next, index: context.index))
      if !wasUserQueuePlaying, let topUserQueueItem = topUserQueueItem {
        queueHandler.insertUserQueue(playables: [topUserQueueItem])
      }
    } else if context.index == 0 {
      insertIntoPlayer(playable: activePlayable)
    } else {
      play(playerIndex: PlayerIndex(queueType: .next, index: context.index - 1))
    }
  }

  func play(playerIndex: PlayerIndex) {
    guard let playable = queueHandler.markAndGetPlayableAsPlaying(at: playerIndex) else {
      stop()
      return
    }
    insertIntoPlayer(playable: playable)
  }

  func playPreviousOrReplay() {
    if shouldCurrentItemReplayedInsteadOfPrevious() {
      replayCurrentItem()
    } else {
      playPrevious()
    }
  }

  // BackendAudioPlayerNotifiable
  func playPrevious() {
    if queueHandler.prevQueueCount > 0 {
      play(playerIndex: PlayerIndex(queueType: .prev, index: queueHandler.prevQueueCount - 1))
    } else if playerStatus.repeatMode == .all, queueHandler.nextQueueCount > 0 {
      play(playerIndex: PlayerIndex(queueType: .next, index: queueHandler.nextQueueCount - 1))
    } else {
      replayCurrentItem()
    }
  }

  // BackendAudioPlayerNotifiable
  func playNext() {
    if let nextPlayerIndex = nextPlayerIndex {
      play(playerIndex: nextPlayerIndex)
    } else if canAutoplay {
      if !preparedAutoplaySongs.isEmpty {
        playAutoplay(at: 0)
      } else {
        awaitingAutoplayAdvance = true
        prepareAutoplayIfNeeded()
        if autoplayTask == nil { pause() }
      }
    } else {
      // Reaching the end keeps the current song, cover and queue position.
      // Explicit Stop/Clear still reset the player through stop().
      pause()
    }
  }

  private var nextPlayerIndex: PlayerIndex? {
    if queueHandler.userQueueCount > 0 {
      return PlayerIndex(queueType: .user, index: 0)
    } else if queueHandler.nextQueueCount > 0 {
      return PlayerIndex(queueType: .next, index: 0)
    } else if playerStatus.repeatMode == .all, queueHandler.prevQueueCount > 0 {
      return PlayerIndex(queueType: .prev, index: 0)
    } else {
      return nil
    }
  }

  func pause() {
    cancelAutoplayRequest()
    if let currentlyPlaying = currentlyPlaying,
       currentlyPlaying.isRadio {
      stopButRemainIndex()
    } else {
      backendAudioPlayer.pause()
      notifyItemPaused()
    }
  }

  // BackendAudioPlayerNotifiable
  func stop() {
    cancelAutoplayRequest(clearQueue: true)
    backendAudioPlayer.stop()
    playerStatus.stop()
    notifyPlayerStopped()
  }

  func stopButRemainIndex() {
    cancelAutoplayRequest(clearQueue: true)
    backendAudioPlayer.stop()
    notifyPlayerStopped()
  }

  func togglePlayPause() {
    if backendAudioPlayer.isPlaying {
      pause()
    } else {
      play()
    }
  }

  private func seekToLastStoppedPlayTime() {
    if let playable = currentlyPlaying,
       playable.playProgress > 0,
       playable
       .isPodcastEpisode ||
       (
         (playable.isSong || backendAudioPlayer.isErrorOccurred) && settings.user
           .isPlayerSongPlaybackResumeEnabled
       ) {
      backendAudioPlayer.seek(toSecond: Double(playable.playProgress))
    }
  }

  // BackendAudioPlayerNotifiable
  func didElapsedTimeChange() {
    notifyElapsedTimeChanged()
    if let currentItem = currentlyPlaying {
      savePlayInformation(of: currentItem)
    }
  }

  // BackendAudioPlayerNotifiable
  func didLyricsTimeChange(time: CMTime) {
    notifyLyricsTimeChanged(time: time)
  }

  // BackendAudioPlayerNotifiable
  func didReadStreamMetadata(_ metadata: [String: String]) {
    guard let radio = currentlyPlaying?.asRadio else { return }
    updateRadioNowPlaying(from: metadata, radio: radio)
  }

  private func savePlayInformation(of playable: AbstractPlayable) {
    let playDuration = backendAudioPlayer.duration
    let playProgress = backendAudioPlayer.elapsedTime
    if playDuration != 0.0, playProgress != 0.0, playable == currentlyPlaying {
      playable.playDuration = Int(playDuration)
      if playProgress > Self.progressTimeStartThreshold,
         playProgress < (playDuration - Self.progressTimeEndThreshold) {
        playable.playProgress = Int(playProgress)
      } else {
        playable.playProgress = 0
      }
    }
  }

  var audioAnalyzer: AudioAnalyzer { backendAudioPlayer.audioAnalyzer }

  func addNotifier(notifier: MusicPlayable) {
    notifierList.append(WeakMusicPlayable(notifier))
  }

  func removeAllNotifier() {
    notifierList.removeAll()
  }

  func notifyItemStartedPlayingFromBeginning() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStartPlayingFromBeginning()
    }
    if let pendingResumeTime {
      self.pendingResumeTime = nil
      backendAudioPlayer.seek(toSecond: pendingResumeTime)
    } else {
      seekToLastStoppedPlayTime()
    }
  }

  func notifyItemStartedPlaying() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStartPlaying()
    }
  }

  // BackendAudioPlayerNotifiable
  func notifyErrorOccurred(error: Error) {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.errorOccurred(error: error)
    }
  }

  func notifyItemPaused() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPause()
    }
  }

  func notifyPlayerStopped() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didStopPlaying()
    }
  }

  func notifyArtworkChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didArtworkChange()
    }
  }

  func notifyElapsedTimeChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didElapsedTimeChange()
    }
  }

  func notifyLyricsTimeChanged(time: CMTime) {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didLyricsTimeChange(time: time)
    }
  }

  func notifyPlaylistUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPlaylistChange()
    }
  }

  func notifyNowPlayingInfoChanged() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didNowPlayingInfoChange()
    }
  }

  func notifyShuffleUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didShuffleChange()
    }
  }

  func notifyRepeatUpdated() {
    autoplaySettingDidChange()
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didRepeatChange()
    }
  }

  func notifyPlaybackRateUpdated() {
    notifierList = notifierList.filter { $0.value != nil }
    for notifier in notifierList {
      notifier.value?.didPlaybackRateChange()
    }
  }

  private func handleRadioStartIfNeeded() {
    guard let radio = currentlyPlaying?.asRadio else {
      if currentRadioNowPlaying != nil {
        currentRadioNowPlaying = nil
        lastRadioStreamTitle = nil
        notifyNowPlayingInfoChanged()
      }
      return
    }

    currentRadioNowPlaying = nil
    lastRadioStreamTitle = nil
    notifyNowPlayingInfoChanged()
  }

  private func updateRadioNowPlaying(from metadata: [String: String], radio: Radio) {
    guard let currentRadio = currentlyPlaying?.asRadio,
          currentRadio.managedObject == radio.managedObject else { return }
    let streamTitleKey = metadata.keys.first { $0.lowercased() == "streamtitle" }
    guard let streamTitleKey,
          let rawStreamTitle = metadata[streamTitleKey]
    else { return }
    let streamTitle = rawStreamTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !streamTitle.isEmpty else { return }
    guard streamTitle != lastRadioStreamTitle else { return }

    let parsedInfo = parseStreamTitle(streamTitle)
    guard let parsedInfo, !parsedInfo.isEmpty else { return }

    lastRadioStreamTitle = streamTitle
    currentRadioNowPlaying = parsedInfo
    notifyNowPlayingInfoChanged()
  }

  private func parseStreamTitle(_ streamTitle: String) -> RadioNowPlayingInfo? {
    let cleaned = streamTitle.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    let parts = cleaned.components(separatedBy: " - ")
    if parts.count >= 2 {
      let artist = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let title = parts.dropFirst().joined(separator: " - ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return RadioNowPlayingInfo(title: title, artist: artist)
    }
    return RadioNowPlayingInfo(title: cleaned, artist: "")
  }
}
