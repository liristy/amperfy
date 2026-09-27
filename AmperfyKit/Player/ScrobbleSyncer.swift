//
//  ScrobbleSyncer.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 05.03.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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
import Foundation
import os.log

// MARK: - ScrobbleSyncer

@MainActor
public class ScrobbleSyncer {
  private static let maximumWaitDurationInSec: TimeInterval =
    240 // scrobble at 4 min or 50% of duration

  private let log = OSLog(subsystem: "Amperfy", category: "ScrobbleSyncer")
  private let player: PlayerFacade
  private let networkMonitor: NetworkMonitorFacade
  private let account: Account
  private let accountObjectId: NSManagedObjectID
  private let storage: PersistentStorage
  private let librarySyncer: LibrarySyncer
  private let eventLogger: EventLogger
  private var isRunning = false
  private var isActive = false
  private var scrobbleTimer: Timer?

  // Track how long the song has actually been played
  private var accumulatedPlayTime: TimeInterval = 0
  private var playStartTimestamp: Date?
  private var currentSongThreshold: TimeInterval = 0

  private var songToBeScrobbled: Song?
  private var hasSubmittedCurrentPlay = false
  private var currentPlayWasCached = false
  private var currentPlayDate: Date?
  private let now: () -> Date

  init(
    player: PlayerFacade,
    networkMonitor: NetworkMonitorFacade,
    account: Account,
    storage: PersistentStorage,
    librarySyncer: LibrarySyncer,
    eventLogger: EventLogger,
    now: @escaping () -> Date = Date.init
  ) {
    self.player = player
    self.networkMonitor = networkMonitor
    self.account = account
    self.accountObjectId = account.managedObject.objectID
    self.storage = storage
    self.librarySyncer = librarySyncer
    self.eventLogger = eventLogger
    self.now = now
  }

  public func start() {
    guard storage.main.library.getUploadableScrobbleEntryCount(for: account) > 0 else { return }
    isRunning = true
    if !isActive {
      isActive = true
      uploadInBackground()
    }
  }

  public func stop() {
    isRunning = false
  }

  private func sendNowPlaying(_ song: Song) {
    guard storage.settings.user.isOnlineMode, networkMonitor.isConnectedToNetwork else { return }
    Task { @MainActor in
      do {
        try await librarySyncer.syncNowPlaying(song: song, songPosition: .start)
      } catch {
        eventLogger.report(topic: "Scrobble Sync", error: error, displayPopup: false)
      }
    }
  }

  private func uploadInBackground() {
    Task { @MainActor in
      os_log("start", log: self.log, type: .info)

      while self.isRunning, self.storage.settings.user.isOnlineMode,
            self.networkMonitor.isConnectedToNetwork {
        do {
          let scobbleEntry = try await self.getNextScrobbleEntry()
          guard let entry = scobbleEntry else {
            self.isRunning = false
            continue
          }
          guard let song = entry.playable?.asSong, let date = entry.date else {
            entry.isUploaded = true
            self.storage.main.saveContext()
            continue
          }
          try await self.librarySyncer.scrobble(song: song, date: date)
          entry.isUploaded = true
          self.storage.main.saveContext()
        } catch {
          self.isRunning = false
          self.eventLogger.report(topic: "Scrobble Sync", error: error, displayPopup: false)
        }
      }

      os_log("stopped", log: self.log, type: .info)
      self.isActive = false
    }
  }

  private func getNextScrobbleEntry() async throws -> ScrobbleEntry? {
    let scobbleObjectId: NSManagedObjectID? = try? await storage.async
      .performAndGet { asyncCompanion in
        let accountAsync = asyncCompanion.library.getAccount(managedObjectId: self.accountObjectId)
        guard let scobbleEntry = asyncCompanion.library
          .getFirstUploadableScrobbleEntry(for: accountAsync) else {
          return nil
        }
        return scobbleEntry.managedObject.objectID
      }
    guard let scobbleObjectId else { return nil }
    return ScrobbleEntry(
      managedObject: try! storage.main.context
        .existingObject(with: scobbleObjectId) as! ScrobbleEntryMO
    )
  }

  private func cacheScrobbleRequest(playedSong: Song, date: Date, isUploaded: Bool) {
    if !isUploaded {
      os_log("Scrobble cache: %s", log: self.log, type: .info, playedSong.displayString)
    }
    let scrobbleEntry = storage.main.library.createScrobbleEntry(account: account)
    scrobbleEntry.date = date
    scrobbleEntry.playable = playedSong
    scrobbleEntry.isUploaded = isUploaded
    storage.main.saveContext()
  }

  private func beginPlay(_ song: Song) {
    finishCurrentPlay()
    songToBeScrobbled = song
    currentPlayDate = now()
    currentPlayWasCached = player.playType == .cache
    playStartTimestamp = player.isPlaying ? now() : nil
    let duration = TimeInterval(song.duration)
    currentSongThreshold = duration > 0 ? min(duration / 2, Self.maximumWaitDurationInSec) : Self.maximumWaitDurationInSec
    scheduleSubmission()
  }

  private func scheduleSubmission() {
    scrobbleTimer?.invalidate()
    guard !hasSubmittedCurrentPlay, playStartTimestamp != nil else { return }
    let remaining = max(0.1, currentSongThreshold - listenedTime)
    let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.submitIfEligible() }
    }
    scrobbleTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private var listenedTime: TimeInterval {
    accumulatedPlayTime + (playStartTimestamp.map { max(0, now().timeIntervalSince($0)) } ?? 0)
  }

  private func submitIfEligible() {
    guard !hasSubmittedCurrentPlay, let song = songToBeScrobbled,
          let date = currentPlayDate, listenedTime >= currentSongThreshold,
          currentPlayWasCached || storage.settings.accounts.getSetting(account.info).read.isScrobbleStreamedItems
    else { return }
    // Mark and persist synchronously before starting network work. Pause/resume,
    // delayed timer callbacks and gapless transitions cannot submit this play twice.
    hasSubmittedCurrentPlay = true
    scrobbleTimer?.invalidate()
    scrobbleTimer = nil
    cacheScrobbleRequest(playedSong: song, date: date, isUploaded: false)
    start()
  }

  private func finishCurrentPlay() {
    submitIfEligible()
    scrobbleTimer?.invalidate()
    scrobbleTimer = nil
    songToBeScrobbled = nil
    currentPlayDate = nil
    hasSubmittedCurrentPlay = false
    currentPlayWasCached = false
    accumulatedPlayTime = 0
    playStartTimestamp = nil
    currentSongThreshold = 0
  }
}

// MARK: MusicPlayable

extension ScrobbleSyncer: MusicPlayable {
  public func didStartPlayingFromBeginning() {
    guard let song = player.currentlyPlaying?.asSong, song.account == account else {
      finishCurrentPlay()
      return
    }
    // Capture the song now, before an asynchronous task could observe a later track.
    beginPlay(song)
  }

  public func didStartPlaying() {
    guard player.isPlaying, let song = player.currentlyPlaying?.asSong, song.account == account else { return }
    if songToBeScrobbled != song {
      beginPlay(song)
    } else if playStartTimestamp == nil {
      playStartTimestamp = now()
      scheduleSubmission()
    }
    sendNowPlaying(song)
    start() // Retry persisted listens when playback resumes after a network failure.
  }

  public func didPause() {
    accumulatedPlayTime = listenedTime
    playStartTimestamp = nil
    submitIfEligible()
    scrobbleTimer?.invalidate()
    scrobbleTimer = nil
  }

  public func didStopPlaying() { finishCurrentPlay() }

  // The timer and playback updates cover background playback and delayed run-loop
  // delivery. Seek position is deliberately not used as listening duration.
  public func didElapsedTimeChange() { submitIfEligible() }
  public func didPlaylistChange() {}
  public func didArtworkChange() {}
  public func didShuffleChange() {}
  public func didRepeatChange() {}
  public func didPlaybackRateChange() {}
}
