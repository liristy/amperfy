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

    if let currentlyPlaying = appDelegate.player.currentlyPlaying,
       let rootView = rootView {
      button.showsMenuAsPrimaryAction = true
      button.menu = UIMenu.lazyMenu {
        EntityPreviewActionBuilder(container: currentlyPlaying, on: rootView).createMenuActions()
      }
      button.isEnabled = true
    } else {
      button.isEnabled = false
    }
  }

  func refreshFavoriteButton(button: UIButton) {
    var config = UIButton.Configuration.player(isSelected: false)
    config.preferredSymbolConfigurationForImage = .init(pointSize: 21, weight: .regular)
    switch player.playerMode {
    case .music:
      if let playableInfo = player.currentlyPlaying,
         playableInfo.isSong {
        config.image = playableInfo.isFavorite ? .starFill : .starEmpty
        config.baseForegroundColor = playableInfo.isFavorite ? appDelegate.storage.settings.accounts
          .getSetting(playableInfo.account?.info).read.themePreference.asColor : .label
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
    artworkGradientColors = [preference.themePreference.asColor, .darkGray]
    applyGradientBackground()
    guard let path else { return }
    backgroundArtworkTask = Task { @MainActor [weak self] in
      guard let image = await LibraryEntityImage.loadPreparedImage(at: path), !Task.isCancelled else { return }
      let colors = await Task.detached(priority: .userInitiated) {
        (try? image.dominantColors(max: 2)) ?? []
      }.value
      guard !Task.isCancelled, let self, self.backgroundArtworkKey == key else { return }
      if !colors.isEmpty { self.artworkGradientColors = colors }
      self.applyGradientBackground()
    }
  }

  internal func applyGradientBackground() {
    func shaded(_ color: UIColor, brightness: CGFloat) -> CGColor {
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      return UIColor(
        red: red * brightness + 0.04,
        green: green * brightness + 0.04,
        blue: blue * brightness + 0.04,
        alpha: 1
      ).cgColor
    }
    let first = artworkGradientColors.first ?? .darkGray
    let last = artworkGradientColors.last ?? first
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    artworkGradientLayer.frame = backgroundImage.bounds
    artworkGradientLayer.colors = [
      shaded(first, brightness: 0.38),
      shaded(last, brightness: 0.26),
      shaded(first, brightness: 0.14),
    ]
    artworkGradientLayer.locations = [0, 0.55, 1]
    artworkGradientLayer.startPoint = CGPoint(x: 0, y: 0)
    artworkGradientLayer.endPoint = CGPoint(x: 1, y: 1)
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
