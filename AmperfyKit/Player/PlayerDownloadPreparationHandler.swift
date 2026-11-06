//
//  PlayerDownloadPreparationHandler.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 25.11.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

import Foundation

// MARK: - PlayerDownloadPreparationHandler

@MainActor
public class PlayerDownloadPreparationHandler {
  static public let preDownloadCount = 3

  private let playerStatus: PlayerStatusPersistent
  private let musicPlayer: AudioPlayer
  private let settings: AmperfySettings
  private let getPlayableDownloaderCB: GetPlayableDownloadManagerCallback
  private let getArtworkDownloaderCB: GetArtworkDownloadManagerCallback
  private let getLibrarySyncerCB: GetLibrarySyncerCallback
  private var accountNotificationHandler: AccountNotificationHandler?
  private var upcomingItems = [AbstractPlayable]()
  private var metadataTasks = [String: Task<Void, Never>]()
  private var preparedMetadata = Set<String>()
  private var artworkTasks = [String: Task<Void, Never>]()

  init(
    playerStatus: PlayerStatusPersistent,
    musicPlayer: AudioPlayer,
    storage: PersistentStorage,
    notificationHandler: EventNotificationHandler,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback,
    getArtworkDownloaderCB: @escaping GetArtworkDownloadManagerCallback,
    getLibrarySyncerCB: @escaping GetLibrarySyncerCallback
  ) {
    self.playerStatus = playerStatus
    self.musicPlayer = musicPlayer
    self.settings = storage.settings
    self.getPlayableDownloaderCB = getPlayableDownloaderCB
    self.getArtworkDownloaderCB = getArtworkDownloaderCB
    self.getLibrarySyncerCB = getLibrarySyncerCB
    accountNotificationHandler = AccountNotificationHandler(storage: storage, notificationHandler: notificationHandler)
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      for downloader in [getArtworkDownloaderCB(accountInfo), getPlayableDownloaderCB(accountInfo)] {
        notificationHandler.register(self, selector: #selector(downloadFinishedSuccessful(notification:)),
          name: .downloadFinishedSuccess, object: downloader)
      }
    }
  }

  private func preDownloadNextItems() {
    upcomingItems = musicPlayer.upcomingPlayablesForPreparation(limit: Self.preDownloadCount)
    let ids = Set(upcomingItems.map { $0.uniqueID })
    for id in Array(metadataTasks.keys) where !ids.contains(id) || musicPlayer.isOfflineMode {
      metadataTasks.removeValue(forKey: id)?.cancel()
    }
    preparedMetadata.formIntersection(ids)
    for playable in upcomingItems {
      prepareArtwork(for: playable)
      guard !musicPlayer.isOfflineMode, let accountInfo = playable.account?.info else { continue }
      // Downloads still honor the existing auto-cache, network and disk-limit policies.
      if playerStatus.isAutoCachePlayedItems, !playable.isCached, playable.isDownloadAvailable {
        getPlayableDownloaderCB(accountInfo).download(object: playable)
      }
      guard let song = playable.asSong, !song.id.isEmpty,
            song.title.isEmpty || song.artist == nil || song.album == nil || song.artwork == nil,
            !preparedMetadata.contains(song.uniqueID), metadataTasks[song.uniqueID] == nil else { continue }
      let id = song.uniqueID
      let syncer = getLibrarySyncerCB(accountInfo)
      metadataTasks[id] = Task { @MainActor [weak self] in
        do {
          try await syncer.sync(song: song)
          guard !Task.isCancelled, let self else { return }
          preparedMetadata.insert(id)
          metadataTasks[id] = nil
          prepareArtwork(for: song)
        } catch {
          guard !Task.isCancelled else { return }
          // Speculative metadata failure must not interrupt the playing track.
          self?.metadataTasks[id] = nil
        }
      }
    }
    let paths = Set(upcomingItems.compactMap { playable -> String? in
      guard let account = playable.account?.info else { return nil }
      return playable.imagePath(setting: settings.accounts.getSetting(account).read.artworkDisplayPreference)
    })
    for path in Array(artworkTasks.keys) where !paths.contains(path) {
      artworkTasks.removeValue(forKey: path)?.cancel()
    }
  }

  private func prepareArtwork(for playable: AbstractPlayable) {
    guard let accountInfo = playable.account?.info else { return }
    let preference = settings.accounts.getSetting(accountInfo).read.artworkDisplayPreference
    if !musicPlayer.isOfflineMode, preference != .id3TagOnly,
       let artwork = playable.artwork, !artwork.isCached {
      getArtworkDownloaderCB(accountInfo).download(object: artwork)
    }
    guard let path = playable.imagePath(setting: preference),
          LibraryEntityImage.preparedImage(at: path) == nil, artworkTasks[path] == nil else { return }
    artworkTasks[path] = Task { @MainActor [weak self] in
      // Decode before advancing: Now Playing and both player views share this cache.
      _ = await LibraryEntityImage.loadPreparedImage(at: path)
      guard !Task.isCancelled else { return }
      self?.artworkTasks[path] = nil
    }
  }

  @objc private func downloadFinishedSuccessful(notification: Notification) {
    guard let download = DownloadNotification.fromNotification(notification) else { return }
    for playable in upcomingItems where playable.uniqueID == download.id || playable.artwork?.uniqueID == download.id {
      // Audio completion can also supply an embedded cover.
      prepareArtwork(for: playable)
    }
  }
}

// MARK: MusicPlayable

extension PlayerDownloadPreparationHandler: MusicPlayable {
  public func didStartPlayingFromBeginning() { preDownloadNextItems() }
  public func didStartPlaying() { preDownloadNextItems() }
  public func didPause() {}
  public func didStopPlaying() {
    metadataTasks.values.forEach { $0.cancel() }
    artworkTasks.values.forEach { $0.cancel() }
    metadataTasks.removeAll()
    artworkTasks.removeAll()
    preparedMetadata.removeAll()
    upcomingItems.removeAll()
  }
  public func didElapsedTimeChange() {}
  public func didPlaylistChange() { preDownloadNextItems() }
  public func didArtworkChange() { preDownloadNextItems() }
  public func didPlaybackRateChange() {}
  public func didRepeatChange() { preDownloadNextItems() }
  public func didShuffleChange() { preDownloadNextItems() }
}
