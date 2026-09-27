//
//  NowPlayingInfoCenterHandler.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 23.11.21.
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
import MediaPlayer

// MARK: - NowPlayingInfoCenterHandler

@MainActor
public class NowPlayingInfoCenterHandler {
  private let musicPlayer: AudioPlayer
  private let backendAudioPlayer: BackendAudioPlayer
  private let storage: PersistentStorage
  private var nowPlayingInfoCenter: MPNowPlayingInfoCenter
  private let getArtworkDownloaderCB: GetArtworkDownloadManagerCallback
  private var accountNotificationHandler: AccountNotificationHandler?
  private var currentPlayableID: String?
  private var artworkPath: String?
  private var artworkImage: UIImage?
  private var artworkTask: Task<Void, Never>?

  init(
    musicPlayer: AudioPlayer,
    backendAudioPlayer: BackendAudioPlayer,
    nowPlayingInfoCenter: MPNowPlayingInfoCenter,
    storage: PersistentStorage,
    notificationHandler: EventNotificationHandler,
    getArtworkDownloaderCB: @escaping GetArtworkDownloadManagerCallback,
    getPlayableDownloaderCB: @escaping GetPlayableDownloadManagerCallback
  ) {
    self.musicPlayer = musicPlayer
    self.backendAudioPlayer = backendAudioPlayer
    self.nowPlayingInfoCenter = nowPlayingInfoCenter
    self.storage = storage
    self.getArtworkDownloaderCB = getArtworkDownloaderCB

    nowPlayingInfoCenter.playbackState = .stopped

    self.accountNotificationHandler = AccountNotificationHandler(
      storage: storage,
      notificationHandler: notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: getArtworkDownloaderCB(accountInfo)
      )
      notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: getPlayableDownloaderCB(accountInfo)
      )
    }
  }

  private func updateNowPlayingInfo(playable: AbstractPlayable) {
    let albumTitle = playable.asSong?.album?.name ?? ""
    let nowPlaying = displayNowPlayingInfo(for: playable)

    if currentPlayableID != playable.uniqueID {
      artworkTask?.cancel()
      artworkTask = nil
      artworkPath = nil
      artworkImage = nil
      currentPlayableID = playable.uniqueID
    }
    if let accountInfo = playable.account?.info {
      if artworkImage == nil {
        let preferences = storage.settings.accounts.getSetting(accountInfo).read
        artworkImage = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: playable,
          themePreference: preferences.themePreference,
          artworkDisplayPreference: preferences.artworkDisplayPreference,
          useCache: true
        )
      }
      if let artwork = playable.artwork {
        getArtworkDownloaderCB(accountInfo).downloadWithPriority(object: artwork)
      }
    }

    let concurrentSafeArtworkImage = artworkImage ?? UIImage()
    nowPlayingInfoCenter.nowPlayingInfo = [
      MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
      MPNowPlayingInfoPropertyServiceIdentifier: AmperKit.name,

      MPMediaItemPropertyIsCloudItem: !playable.isCached,
      MPMediaItemPropertyTitle: nowPlaying.title,
      MPMediaItemPropertyAlbumTitle: albumTitle,
      MPMediaItemPropertyArtist: nowPlaying.artist,

      MPMediaItemPropertyPlaybackDuration: backendAudioPlayer.duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: backendAudioPlayer.elapsedTime,
      MPNowPlayingInfoPropertyIsLiveStream: playable.isRadio,

      MPNowPlayingInfoPropertyDefaultPlaybackRate: NSNumber(value: 1.0),
      MPNowPlayingInfoPropertyPlaybackRate: NSNumber(
        value: musicPlayer.isPlaying ? backendAudioPlayer.playbackRate.asDouble : 0
      ),

      MPMediaItemPropertyArtwork: MPMediaItemArtwork(
        boundsSize: concurrentSafeArtworkImage.size,
        requestHandler: { @Sendable size -> UIImage in
          // this completion handler is not called in main thread!
          return concurrentSafeArtworkImage
        }
      ),
    ]
    loadArtwork(for: playable)
  }

  // This handler lives independently of the player UI, including while locked.
  private func loadArtwork(for playable: AbstractPlayable) {
    guard let accountInfo = playable.account?.info else { return }
    let preference = storage.settings.accounts.getSetting(accountInfo).read.artworkDisplayPreference
    let path = playable.imagePath(setting: preference)
    guard path != artworkPath else { return }
    artworkTask?.cancel()
    artworkPath = path
    guard let path else { return }
    let playableID = playable.uniqueID
    artworkTask = Task { @MainActor [weak self] in
      let image = await LibraryEntityImage.loadPreparedImage(at: path)
      guard !Task.isCancelled, let self,
            self.currentPlayableID == playableID,
            self.musicPlayer.currentlyPlaying?.uniqueID == playableID,
            self.artworkPath == path else { return }
      self.artworkTask = nil
      guard let image else {
        self.artworkPath = nil
        return
      }
      self.artworkImage = image
      // Merge just artwork so a late decode cannot reset the elapsed time or
      // overwrite metadata belonging to a newly started song.
      guard var info = self.nowPlayingInfoCenter.nowPlayingInfo else { return }
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
      self.nowPlayingInfoCenter.nowPlayingInfo = info
    }
  }

  private func updatePlaybackTiming() {
    guard var info = nowPlayingInfoCenter.nowPlayingInfo else { return }
    info[MPMediaItemPropertyPlaybackDuration] = backendAudioPlayer.duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = backendAudioPlayer.elapsedTime
    info[MPNowPlayingInfoPropertyPlaybackRate] = musicPlayer.isPlaying ? backendAudioPlayer.playbackRate.asDouble : 0
    nowPlayingInfoCenter.nowPlayingInfo = info
  }

  private func displayNowPlayingInfo(for playable: AbstractPlayable) -> RadioNowPlayingInfo {
    if playable.isRadio,
       let radioInfo = musicPlayer.currentRadioNowPlaying,
       !radioInfo.isEmpty {
      return radioInfo
    }
    return RadioNowPlayingInfo(title: playable.title, artist: playable.creatorName)
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = musicPlayer.currentlyPlaying
    else { return }
    if curPlayable.uniqueID == downloadNotification.id ||
       curPlayable.artwork?.uniqueID == downloadNotification.id {
      updateNowPlayingInfo(playable: curPlayable)
    }
  }
}

// MARK: MusicPlayable

extension NowPlayingInfoCenterHandler: MusicPlayable {
  public func didStartPlayingFromBeginning() {}

  public func didStartPlaying() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
    nowPlayingInfoCenter.playbackState = .playing
  }

  public func didPause() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
    nowPlayingInfoCenter.playbackState = .paused
  }

  public func didStopPlaying() {
    artworkTask?.cancel()
    artworkTask = nil
    artworkPath = nil
    artworkImage = nil
    currentPlayableID = nil
    nowPlayingInfoCenter.nowPlayingInfo = nil
    nowPlayingInfoCenter.playbackState = .stopped
  }

  public func didElapsedTimeChange() {
    if let playable = musicPlayer.currentlyPlaying, playable.uniqueID != currentPlayableID {
      updateNowPlayingInfo(playable: playable)
    } else {
      updatePlaybackTiming()
    }
  }

  public func didPlaylistChange() {}

  public func didArtworkChange() {
    if let playable = musicPlayer.currentlyPlaying { updateNowPlayingInfo(playable: playable) }
  }

  public func didNowPlayingInfoChange() {
    if let curPlayable = musicPlayer.currentlyPlaying {
      updateNowPlayingInfo(playable: curPlayable)
    }
  }

  public func didShuffleChange() {}

  public func didRepeatChange() {}

  public func didPlaybackRateChange() { updatePlaybackTiming() }
}
