//
//  PopupPlayer+Visuals.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 11.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import DominantColors
import UIKit

extension PopupPlayerVC {
  func refresh() {
    refreshContextQueueSectionHeader()
    refreshUserQueueSectionHeader()
    refreshCellMasks()
    refreshCellsContent()
    refreshCurrentlyPlayingInfoView()
  }

  func refreshCurrentlyPlayingInfoView() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refresh()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refresh()
        break
      }
    }
  }

  func refreshCurrentlyPlayingArtworks() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refreshArtwork()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refreshArtwork()
        break
      }
    }
  }

  func refreshOptionButton(button: UIButton, rootView: UIViewController?) {
    var config = UIButton.Configuration.player(isSelected: false)
    config.preferredSymbolConfigurationForImage = .init(pointSize: 21, weight: .semibold)
    config.image = .ellipsis
    config.baseForegroundColor = .label
    button.isEnabled = true
    button.configuration = config

    button.accessibilityLabel = "Player options".localized
    button.showsMenuAsPrimaryAction = true
    button.menu = UIMenu.lazyMenu { [weak self, weak rootView] in
      guard let self else { return [] }
      var sections = [UIMenuElement]()
      if let song = self.player.currentlyPlaying, let rootView {
        sections.append(UIMenu(options: .displayInline, children:
          EntityPreviewActionBuilder(container: song, on: rootView).createMenuActions()))
      }
      if let controls = self.controlView {
        sections.append(UIMenu(options: .displayInline, children: controls.createPlayerOptionsMenu()))
      }
      return sections
    }
  }

  func refreshFavoriteButton(button: UIButton) {
    var config = UIButton.Configuration.player(isSelected: false)
    config.preferredSymbolConfigurationForImage = .init(pointSize: 21, weight: .regular)
    switch player.playerMode {
    case .music:
      if let playableInfo = player.currentlyPlaying,
         playableInfo.isSong {
        config = .player(isSelected: playableInfo.isFavorite)
        config.preferredSymbolConfigurationForImage = .init(pointSize: 21, weight: .regular)
        config.image = playableInfo.isFavorite ? .starFill : .starEmpty
        button.isEnabled = appDelegate.storage.settings.user.isOnlineMode
      } else if let playableInfo = player.currentlyPlaying,
                let radio = playableInfo.asRadio {
        config.image = .followLink
        config.baseForegroundColor = .label
        button.isEnabled = radio.siteURL != nil
      } else {
        config.image = .starEmpty
        config.baseForegroundColor = .label
        button.isEnabled = false
      }
    case .podcast:
      config.image = .info
      config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .large)
      config.baseForegroundColor = .label
      button.isEnabled = true
    }
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    button.configuration = config
  }

  func refreshBackgroundItemArtwork() {
    let settings = appDelegate.storage.settings
    let playable = player.currentlyPlaying
    let account = playable?.account?.info ?? settings.accounts.active
    let preference = account.map { settings.accounts.getSetting($0).read }
      ?? settings.accounts.activeSetting.read
    let path = playable?.imagePath(setting: preference.artworkDisplayPreference)
    let key = path ?? "placeholder-\(preference.themePreference.assetName)"
    guard backgroundArtworkKey != key else { return }
    backgroundArtworkKey = key
    backgroundArtworkTask?.cancel()
    // Do not flash the account's accent color while artwork is decoded.
    // Reopening the same cover starts with its final palette immediately.
    if let cached = Self.backgroundPaletteCache.object(forKey: key as NSString) as? [UIColor] {
      artworkGradientColors = cached
    } else if artworkGradientColors.isEmpty || path == nil {
      artworkGradientColors = [.darkGray, .darkGray]
    }
    applyGradientBackground()
    guard let path else { return }
    backgroundArtworkTask = Task { @MainActor [weak self] in
      guard let image = await LibraryEntityImage.loadPreparedImage(at: path), !Task.isCancelled else { return }
      let colors = await Task.detached(priority: .userInitiated) {
        (try? image.dominantColors(max: 3)) ?? []
      }.value
      guard !Task.isCancelled, let self, self.backgroundArtworkKey == key else { return }
      if !colors.isEmpty {
        self.artworkGradientColors = colors
        Self.backgroundPaletteCache.setObject(colors as NSArray, forKey: key as NSString)
      }
      self.applyGradientBackground(animated: true)
    }
  }

  internal func applyGradientBackground(animated: Bool = false) {
    func shaded(_ color: UIColor, brightness: CGFloat) -> CGColor {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      let neutral = red * 0.2126 + green * 0.7152 + blue * 0.0722
      let shadedRed = (red * 0.72 + neutral * 0.28) * brightness + 0.08
      let shadedGreen = (green * 0.72 + neutral * 0.28) * brightness + 0.08
      let shadedBlue = (blue * 0.72 + neutral * 0.28) * brightness + 0.08
      // White or very bright covers must not wash out the white controls.
      let luminance = shadedRed * 0.2126 + shadedGreen * 0.7152 + shadedBlue * 0.0722
      let attenuation = min(1, 0.4 / max(luminance, 0.001))
      return UIColor(
        red: shadedRed * attenuation,
        green: shadedGreen * attenuation,
        blue: shadedBlue * attenuation,
        alpha: 1
      ).cgColor
    }
    let layers = [artworkGradientLayer] + artworkColorLayers
    let previousColors = layers.map { $0.presentation()?.colors ?? $0.colors }
    let first = artworkGradientColors.first ?? .darkGray
    let last = artworkGradientColors.last ?? first
    let accent = artworkGradientColors.count > 1 ? artworkGradientColors[1] : first
    let palette = [first, accent, last, first]
    let geometryChanged = artworkMotionSize != backgroundImage.bounds.size
    if geometryChanged { stopAmbientAnimation() }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    artworkGradientLayer.frame = backgroundImage.bounds
    artworkAmbientLayer.frame = backgroundImage.bounds
    artworkGradientLayer.colors = [
      shaded(first, brightness: 0.55),
      shaded(last, brightness: 0.45),
      shaded(first, brightness: 0.34),
    ]
    artworkGradientLayer.locations = [0, 0.55, 1]
    artworkGradientLayer.startPoint = CGPoint(x: 0, y: 0)
    artworkGradientLayer.endPoint = CGPoint(x: 1, y: 1)
    // Overlapping elliptical color fields form a soft artwork-colored mesh.
    // Gradients already feather to transparent; no live blur or bitmap redraw
    // is needed as the compositor moves, rotates and stretches the fields.
    let diameter = max(backgroundImage.bounds.width, backgroundImage.bounds.height)
    let centers = [CGPoint(x: 0.05, y: 0.15), CGPoint(x: 0.9, y: 0.38),
                   CGPoint(x: 0.2, y: 0.95), CGPoint(x: 0.85, y: 0.9)]
    for (index, layer) in artworkColorLayers.enumerated() {
      if geometryChanged { layer.transform = CATransform3DIdentity }
      layer.bounds = CGRect(x: 0, y: 0, width: diameter * (index.isMultiple(of: 2) ? 1 : 0.75),
                            height: diameter * (index.isMultiple(of: 2) ? 0.7 : 1))
      layer.position = CGPoint(x: backgroundImage.bounds.width * centers[index].x,
                               y: backgroundImage.bounds.height * centers[index].y)
      let color = UIColor(cgColor: shaded(palette[index], brightness: 0.85))
      layer.colors = [color.withAlphaComponent(0.9).cgColor,
                      color.withAlphaComponent(0.65).cgColor,
                      color.withAlphaComponent(0.18).cgColor,
                      color.withAlphaComponent(0).cgColor]
    }
    artworkMotionSize = backgroundImage.bounds.size
    CATransaction.commit()
    if animated, view.window != nil, !UIAccessibility.isReduceMotionEnabled {
      for (index, layer) in layers.enumerated() {
        guard let previous = previousColors[index] else { continue }
        let fade = CABasicAnimation(keyPath: "colors")
        fade.fromValue = previous
        fade.toValue = layer.colors
        fade.duration = 0.9
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "artwork-palette")
      }
    }
    updateAmbientAnimation()
  }

  internal var isAmbientMotionRunning: Bool {
    artworkColorLayers.contains { $0.animation(forKey: "ambient-flow") != nil }
  }

  internal func setPlayerPresentationVisible(_ visible: Bool) {
    isPlayerPresentationVisible = visible
    controlView?.setPlaybackPresentationActive(visible && !areLyricsControlsHidden)
    updateAmbientAnimation()
  }

  @objc internal func ambientEnvironmentChanged(_ notification: Notification) {
    if notification.name == UIApplication.didBecomeActiveNotification { isAmbientApplicationActive = true }
    if notification.name == UIApplication.willResignActiveNotification ||
      notification.name == UIApplication.didEnterBackgroundNotification { isAmbientApplicationActive = false }
    updateAmbientAnimation()
  }

  internal func updateAmbientAnimation() {
    guard isPlayerPresentationVisible, isAmbientApplicationActive, viewIfLoaded?.window != nil,
          player?.isPlaying == true, artworkMotionSize.width > 0,
          !UIAccessibility.isReduceMotionEnabled, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
      stopAmbientAnimation()
      return
    }
    for (index, layer) in artworkColorLayers.enumerated() {
      guard layer.animation(forKey: "ambient-flow") == nil else { continue }
      let current = layer.transform
      let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
      let offsets = [CGPoint(x: 0.22, y: -0.16), CGPoint(x: -0.18, y: -0.08),
                     CGPoint(x: -0.12, y: 0.18), CGPoint(x: 0.16, y: 0.12)]
      var transforms = [NSValue(caTransform3D: current)]
      for step in 0..<4 {
        let offset = offsets[(step + index) % offsets.count]
        var transform = CATransform3DMakeTranslation(
          artworkMotionSize.width * offset.x * direction,
          artworkMotionSize.height * offset.y * direction, 0)
        transform = CATransform3DRotate(transform, direction * (step.isMultiple(of: 2) ? 0.32 : -0.24), 0, 0, 1)
        let scale: CGFloat = step.isMultiple(of: 2) ? 1.18 : 0.94
        transform = CATransform3DScale(transform, scale, scale, 1)
        transforms.append(NSValue(caTransform3D: transform))
      }
      transforms.append(NSValue(caTransform3D: current))
      let flow = CAKeyframeAnimation(keyPath: "transform")
      flow.values = transforms
      flow.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
      flow.timingFunctions = (0..<5).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
      flow.duration = 24 + Double(index) * 7
      flow.repeatCount = .infinity
      layer.add(flow, forKey: "ambient-flow")
    }
  }

  private func stopAmbientAnimation() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for layer in artworkColorLayers where layer.animation(forKey: "ambient-flow") != nil {
      // Keep the complete rendered transform, so resuming begins at this frame.
      if let transform = layer.presentation()?.transform { layer.transform = transform }
      layer.removeAnimation(forKey: "ambient-flow")
    }
    CATransaction.commit()
  }

  @objc
  internal func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = player.currentlyPlaying
    else { return }
    if curPlayable.uniqueID == downloadNotification.id {
      backgroundArtworkKey = nil
      refreshBackgroundItemArtwork()
    }
    if let artwork = curPlayable.artwork,
       artwork.uniqueID == downloadNotification.id {
      backgroundArtworkKey = nil
      refreshBackgroundItemArtwork()
    }
  }

  func adjustLayoutMargins() {
    let isLandscape = view.bounds.width > 600 && view.bounds.height < 500
    let inset = max(24, (view.bounds.width - (isLandscape ? 1000 : 520)) / 2)
    view.layoutMargins = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
  }
}

#if DEBUG
@MainActor
func verifyPlayerAmbientFlow(_ popup: PopupPlayerVC,
                            screenshot: @MainActor @Sendable (String) async throws -> Void) async throws {
  func fail(_ message: String) -> NSError {
    NSError(domain: "PlayerAmbientSmoke", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }
  guard popup.artworkColorLayers.count == 4 else { throw fail("Incomplete artwork mesh") }
  let initial = popup.artworkColorLayers.map { ($0.presentation() ?? $0).transform }
  try await screenshot("player-ambient-flow-start.png")
  try await Task.sleep(for: .seconds(5))
  let moved = popup.artworkColorLayers.map { ($0.presentation() ?? $0).transform }
  guard zip(initial, moved).allSatisfy({ pair in
    abs(pair.0.m41 - pair.1.m41) + abs(pair.0.m42 - pair.1.m42) > 1
  }) else {
    throw fail("Artwork mesh did not visibly flow during playback")
  }
  try await screenshot("player-ambient-flow-moved.png")
  popup.applyGradientBackground(animated: true)
  guard popup.isAmbientMotionRunning else { throw fail("Palette refresh stopped mesh motion") }
  popup.ambientEnvironmentChanged(Notification(name: UIApplication.willResignActiveNotification))
  guard !popup.isAmbientMotionRunning else { throw fail("Inactive app kept mesh motion running") }
  let frozen = popup.artworkColorLayers.map { $0.transform }
  try await Task.sleep(for: .milliseconds(150))
  guard zip(frozen, popup.artworkColorLayers).allSatisfy({ pair in
    CATransform3DEqualToTransform(pair.0, pair.1.transform)
  }) else {
    throw fail("Frozen artwork mesh continued moving")
  }
  popup.ambientEnvironmentChanged(Notification(name: UIApplication.didBecomeActiveNotification))
  guard popup.isAmbientMotionRunning,
        zip(frozen, popup.artworkColorLayers).allSatisfy({ pair in
    CATransform3DEqualToTransform(pair.0, pair.1.transform)
  }) else {
    throw fail("Resuming mesh motion snapped the artwork geometry")
  }
}
#endif
