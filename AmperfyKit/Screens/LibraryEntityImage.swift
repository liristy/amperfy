//
//  LibraryEntityImage.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 10.06.21.
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

import CoreData
import ImageIO
import UIKit

extension LibraryEntityImage {
  // Cache should not be used between different instances -> iOS and Carplay
  static public func getImageToDisplayImmediately(
    libraryEntity: AbstractLibraryEntity,
    themePreference: ThemePreference,
    artworkDisplayPreference: ArtworkDisplayPreference,
    useCache: Bool
  )
    -> UIImage {
    if let artworkImagePath = libraryEntity.imagePath(
      setting: artworkDisplayPreference
    ) {
      if useCache, let cachedImg = Self.cache.object(forKey: artworkImagePath as NSString) {
        return cachedImg
      } else if !useCache, let directlyLoadedImage = UIImage(contentsOfFile: artworkImagePath) {
        return directlyLoadedImage
      }
    }
    return UIImage.getGeneratedArtwork(
      theme: themePreference,
      artworkType: libraryEntity.getDefaultArtworkType()
    )
  }
}

// MARK: - LibraryEntityImage

@MainActor
public class LibraryEntityImage: RoundedImage {
  static private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.totalCostLimit = 64 * 1024 * 1024
    cache.countLimit = 150
    return cache
  }()
  static private var pendingImages = [String: Task<UIImage?, Never>]()
  private var imageLoadTask: Task<Void, Never>?
  private var requestedImagePath: String?

  // Mini player, full player and visible cells share one disk read and decode.
  public static func loadPreparedImage(at imagePath: String) async -> UIImage? {
    if let image = cache.object(forKey: imagePath as NSString) { return image }
    let task: Task<UIImage?, Never>
    if let pending = pendingImages[imagePath] {
      task = pending
    } else {
      task = Task.detached(priority: .userInitiated) {
        await decodeImage(at: imagePath)
      }
      pendingImages[imagePath] = task
    }
    let image = await task.value
    guard !task.isCancelled else { return nil }
    if let image, let cgImage = image.cgImage {
      cache.setObject(image, forKey: imagePath as NSString,
                      cost: cgImage.bytesPerRow * cgImage.height)
    }
    pendingImages[imagePath] = nil
    return image
  }

  @concurrent
  private static func decodeImage(at path: String) async -> UIImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { return nil }
    return await UIImage(cgImage: thumbnail).byPreparingForDisplay()
  }

  private let appDelegate: AmperKit

  private var serverArtwork: Artwork?
  private var entity: AbstractLibraryEntity?
  private var backupArtworkType: ArtworkType?
  private var accountNotificationHandler: AccountNotificationHandler?

  required public init?(coder: NSCoder) {
    self.appDelegate = AmperKit.shared
    super.init(coder: coder)
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  override public init(frame: CGRect) {
    self.appDelegate = AmperKit.shared
    super.init(frame: .zero)
    self.accountNotificationHandler = AccountNotificationHandler(
      storage: appDelegate.storage,
      notificationHandler: appDelegate.notificationHandler
    )
    accountNotificationHandler?.registerCallbackForAllAccounts { [weak self] accountInfo in
      guard let self else { return }
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).artworkDownloadManager
      )
      appDelegate.notificationHandler.register(
        self,
        selector: #selector(downloadFinishedSuccessful(notification:)),
        name: .downloadFinishedSuccess,
        object: appDelegate.getMeta(accountInfo).playableDownloadManager
      )
    }
  }

  public func display(entity: AbstractLibraryEntity) {
    serverArtwork = nil
    self.entity = entity
    backupArtworkType = entity.getDefaultArtworkType()
    refresh()
  }

  public func displayAndUpdate(entity: AbstractLibraryEntity) {
    display(entity: entity)
    if let artwork = entity.artwork, let accountInfo = entity.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
  }

  public func displayAndUpdate(artwork: Artwork, fallback: ArtworkType) {
    entity = nil
    serverArtwork = artwork
    backupArtworkType = fallback
    refresh()
    if let accountInfo = artwork.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
  }

  internal func display(image: UIImage) {
    imageLoadTask?.cancel()
    requestedImagePath = nil
    serverArtwork = nil
    self.image = image
    entity = nil
  }

  public func display(artworkType: ArtworkType) {
    serverArtwork = nil
    backupArtworkType = artworkType
    entity = nil
    refresh()
  }

  private var placeholderImage: UIImage {
    var theme = appDelegate.storage.settings.accounts.activeSetting.read.themePreference
    if let accountInfo = serverArtwork?.account?.info ?? entity?.account?.info {
      theme = appDelegate.storage.settings.accounts.getSetting(accountInfo).read.themePreference
    }
    return UIImage.getGeneratedArtwork(
      theme: theme,
      artworkType: backupArtworkType ?? .song
    )
  }

  private var entityImagePathToDisplay: String? {
    if let serverArtwork { return serverArtwork.imagePath }
    var artworkDisplayPreference = appDelegate.storage.settings.accounts.activeSetting.read
      .artworkDisplayPreference
    if let accountInfo = serverArtwork?.account?.info ?? entity?.account?.info {
      artworkDisplayPreference = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        .artworkDisplayPreference
    }
    return entity?.imagePath(
      setting: artworkDisplayPreference
    )
  }

  private func refresh() {
    // Albums and playlist covers may be portrait or landscape images.
    if !(entity is Artist) { contentMode = .scaleAspectFit }
    let imagePathToDisplay = entityImagePathToDisplay

    if let imagePathToDisplay,
       let cachedImg = Self.cache.object(forKey: imagePathToDisplay as NSString) {
      imageLoadTask?.cancel()
      imageLoadTask = nil
      requestedImagePath = imagePathToDisplay
      image = cachedImg
      return
    }

    if requestedImagePath == imagePathToDisplay, imageLoadTask != nil { return }
    imageLoadTask?.cancel()
    imageLoadTask = nil
    requestedImagePath = imagePathToDisplay
    image = placeholderImage
    guard let imagePathToDisplay else { return }
    imageLoadTask = Task { @MainActor [weak self] in
      let prepared = await Self.loadPreparedImage(at: imagePathToDisplay)
      guard !Task.isCancelled, let self,
            self.requestedImagePath == imagePathToDisplay else { return }
      self.imageLoadTask = nil
      if let prepared { self.image = prepared }
    }
  }

  @objc
  private func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification) else { return }
    if let serverArtwork, serverArtwork.uniqueID == downloadNotification.id {
      refreshDownloadedImage()
      return
    }
    guard let entity else { return }
    if let playable = entity as? AbstractPlayable,
       playable.uniqueID == downloadNotification.id {
      refreshDownloadedImage()
    }
    if let artwork = entity.artwork,
       artwork.uniqueID == downloadNotification.id {
      refreshDownloadedImage()
    }
  }

  private func refreshDownloadedImage() {
    if let path = entityImagePathToDisplay { Self.cache.removeObject(forKey: path as NSString) }
    imageLoadTask?.cancel()
    imageLoadTask = nil
    refresh()
  }
}
