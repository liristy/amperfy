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

// iOS extrapolates elapsed time from the last published position/rate. Keep
// an anchor on a monotonic clock so wall-clock changes cannot force updates.
struct NowPlayingTimingAnchor {
  let elapsed: Double
  let duration: Double
  let rate: Double
  let uptime: TimeInterval

  func needsUpdate(elapsed: Double, duration: Double, rate: Double, uptime: TimeInterval) -> Bool {
    let expected = self.elapsed + max(0, uptime - self.uptime) * self.rate
    return abs(expected - elapsed) > 0.75 || abs(self.duration - duration) > 0.1 || self.rate != rate
  }
}

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
  private var publishedPlayableID: String?
  private var artworkPath: String?
  private var artworkImage: UIImage?
  private var artworkTask: Task<Void, Never>?
  private var timingAnchor: NowPlayingTimingAnchor?

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
    if currentPlayableID != playable.uniqueID {
      artworkTask?.cancel()
      artworkTask = nil
      artworkPath = nil
      artworkImage = nil
      currentPlayableID = playable.uniqueID
    }
    if let accountInfo = playable.account?.info {
      let preferences = storage.settings.accounts.getSetting(accountInfo).read
      let path = playable.imagePath(setting: preferences.artworkDisplayPreference)
      if let path, let image = LibraryEntityImage.preparedImage(at: path) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkPath = path
        artworkImage = image
      } else if let path, path != artworkPath || artworkTask != nil {
        // A disk-cached cover is real artwork, not a missing cover. Decode it
        // off the main thread, then publish the title and image together.
        loadArtwork(for: playable, at: path)
        return
      }
      if artworkImage == nil {
        artworkImage = LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: playable,
          themePreference: preferences.themePreference,
          artworkDisplayPreference: preferences.artworkDisplayPreference,
          useCache: true
        )
      }
      if !musicPlayer.isOfflineMode, preferences.artworkDisplayPreference != .id3TagOnly,
         let artwork = playable.artwork, !artwork.isCached {
        getArtworkDownloaderCB(accountInfo).downloadWithPriority(object: artwork)
      }
    }
    publishNowPlayingInfo(playable: playable)
  }

  private func publishNowPlayingInfo(playable: AbstractPlayable) {
    let albumTitle = playable.asSong?.album?.name ?? ""
    let nowPlaying = displayNowPlayingInfo(for: playable)
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
        value: backendAudioPlayer.nowPlayingPlaybackRate
      ),

      MPMediaItemPropertyArtwork: MPMediaItemArtwork(
        boundsSize: concurrentSafeArtworkImage.size,
        requestHandler: { @Sendable size -> UIImage in
          // this completion handler is not called in main thread!
          return concurrentSafeArtworkImage
        }
      ),
    ]
    publishedPlayableID = playable.uniqueID
    rememberPlaybackTiming()
  }

  // This handler lives independently of the player UI, including while locked.
  private func loadArtwork(for playable: AbstractPlayable, at path: String) {
    guard path != artworkPath || artworkTask == nil else { return }
    artworkTask?.cancel()
    artworkPath = path
    let playableID = playable.uniqueID
    artworkTask = Task { @MainActor [weak self] in
      let image = await LibraryEntityImage.loadPreparedImage(at: path)
      guard !Task.isCancelled, let self,
            self.currentPlayableID == playableID,
            self.musicPlayer.currentlyPlaying?.uniqueID == playableID,
            self.artworkPath == path else { return }
      self.artworkTask = nil
      self.artworkImage = image
      // Re-read metadata and timing after the await. Never reset the playhead
      // or let a previous track's decode overwrite the current track.
      self.updateNowPlayingInfo(playable: playable)
    }
  }

  private func rememberPlaybackTiming() {
    timingAnchor = NowPlayingTimingAnchor(elapsed: backendAudioPlayer.elapsedTime,
      duration: backendAudioPlayer.duration,
      rate: backendAudioPlayer.nowPlayingPlaybackRate,
      uptime: ProcessInfo.processInfo.systemUptime)
  }

  private func updatePlaybackTiming(force: Bool = false) {
    guard publishedPlayableID == currentPlayableID,
          var info = nowPlayingInfoCenter.nowPlayingInfo else { return }
    let elapsed = backendAudioPlayer.elapsedTime
    let duration = backendAudioPlayer.duration
    let rate = backendAudioPlayer.nowPlayingPlaybackRate
    guard elapsed.isFinite, duration.isFinite else { return }
    if !force, let timingAnchor,
       !timingAnchor.needsUpdate(elapsed: elapsed, duration: duration, rate: rate,
                                uptime: ProcessInfo.processInfo.systemUptime) { return }
    info[MPMediaItemPropertyPlaybackDuration] = duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    info[MPNowPlayingInfoPropertyPlaybackRate] = rate
    nowPlayingInfoCenter.nowPlayingInfo = info
    rememberPlaybackTiming()
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
    publishedPlayableID = nil
    timingAnchor = nil
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

  public func didSeek() { updatePlaybackTiming(force: true) }

  public func didPlaybackRateChange() { updatePlaybackTiming(force: true) }
}
