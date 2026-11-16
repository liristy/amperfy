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
  private var downloadedImageNeedsRefresh = false
  // Only current player artwork opts in. Background track/download events may
  // update this image once; palette extraction and offscreen lists stay separate.
  public var allowsBackgroundImageUpdates = false
  private var canUpdateImage: Bool { Self.areVisualUpdatesEnabled || allowsBackgroundImageUpdates }
  private static let paletteCache = NSCache<NSString, NSArray>()
  // The host supplies lifecycle state; this framework is also used by extensions.
  public static var visualUpdatesAllowed: @MainActor () -> Bool = { false }
  private static var areVisualUpdatesEnabled: Bool { visualUpdatesAllowed() }

  #if DEBUG
    public private(set) static var paletteComputationCount = 0
  #endif

  public static func loadArtworkPalette(at path: String) async -> [UIColor] {
    if let colors = preparedArtworkPalette(at: path) { return colors }
    guard !Task.isCancelled, areVisualUpdatesEnabled,
          let image = await loadPreparedImage(at: path), !Task.isCancelled,
          areVisualUpdatesEnabled else { return [] }
    return cacheArtworkPalette(image: image, path: path)
  }

  // Visible list artwork has already been decoded. Resolve its palette before
  // navigation starts, rather than scheduling a color change after the first frame.
  public static func preparedArtworkPalette(at path: String) -> [UIColor]? {
    if let cached = paletteCache.object(forKey: path as NSString) as? [UIColor] { return cached }
    guard !Task.isCancelled, areVisualUpdatesEnabled,
          let image = cache.object(forKey: path as NSString) else { return nil }
    return cacheArtworkPalette(image: image, path: path)
  }

  // Detail navigation needs its final backdrop before the first visible frame,
  // even when the large decoded cover was evicted. Read only a tiny thumbnail;
  // do not decode/retain a full-size UI image or perform work in the background.
  public static func initialArtworkPalette(at path: String) -> [UIColor]? {
    if let colors = preparedArtworkPalette(at: path) { return colors }
    guard !Task.isCancelled, areVisualUpdatesEnabled,
          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary) else { return nil }
    return cacheArtworkPalette(image: UIImage(cgImage: thumbnail), path: path)
  }

  private static func cacheArtworkPalette(image: UIImage, path: String) -> [UIColor] {
    #if DEBUG
      paletteComputationCount += 1
    #endif
    let colors = image.boundedArtworkPalette()
    if !colors.isEmpty {
      paletteCache.countLimit = 100
      paletteCache.setObject(colors as NSArray, forKey: path as NSString)
    }
    return colors
  }

  public static func preparedImage(at imagePath: String) -> UIImage? {
    cache.object(forKey: imagePath as NSString)
  }

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

  public var preferredArtworkContentMode: UIView.ContentMode? {
    didSet {
      if let preferredArtworkContentMode { contentMode = preferredArtworkContentMode }
    }
  }

  required public init?(coder: NSCoder) {
    self.appDelegate = AmperKit.shared
    super.init(coder: coder)
    observeVisualLifecycle()
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
    observeVisualLifecycle()
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

  private func observeVisualLifecycle() {
    NotificationCenter.default.addObserver(self, selector: #selector(resumeImageDisplay),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(suspendImageDisplay),
      name: UIApplication.willResignActiveNotification, object: nil)
  }

  @objc private func suspendImageDisplay() {
    if !allowsBackgroundImageUpdates { imageLoadTask?.cancel(); imageLoadTask = nil }
  }
  @objc private func resumeImageDisplay() {
    guard window != nil || allowsBackgroundImageUpdates else { return }
    if downloadedImageNeedsRefresh { refreshDownloadedImage() } else { refresh() }
  }

  private func refresh() {
    guard canUpdateImage else { return }
    // Albums and playlist covers may be portrait or landscape images.
    if let preferredArtworkContentMode {
      contentMode = preferredArtworkContentMode
    } else if !(entity is Artist) {
      contentMode = .scaleAspectFit
    }
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
    let keepDisplayedArtwork = imagePathToDisplay != nil &&
      requestedImagePath == imagePathToDisplay && image != nil
    requestedImagePath = imagePathToDisplay
    // A cache eviction or refreshed file must not flash a placeholder between
    // two decodes of the same cover. Reused cells with a new path still reset.
    if !keepDisplayedArtwork { image = placeholderImage }
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
    downloadedImageNeedsRefresh = true
    guard canUpdateImage else { return }
    downloadedImageNeedsRefresh = false
    if let path = entityImagePathToDisplay {
      Self.cache.removeObject(forKey: path as NSString)
      Self.paletteCache.removeObject(forKey: path as NSString)
    }
    imageLoadTask?.cancel()
    imageLoadTask = nil
    refresh()
  }
}
