//
//  ContextQueueSectionHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
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
import MarqueeLabel
import UIKit

// MARK: - ContextQueueNextSectionHeader

class ContextQueueNextSectionHeader: UIView {
  static let frameHeight: CGFloat = 100
  static let margin = UIEdgeInsets(
    top: 8,
    left: UIView.defaultMarginX,
    bottom: 8,
    right: UIView.defaultMarginX
  )

  private var player: PlayerFacade!
  private var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?
  private var usesPlayerLayout = false

  @IBOutlet
  weak var queueNameLabel: UILabel!
  @IBOutlet
  weak var contextNameLabel: MarqueeLabel!

  @IBOutlet
  weak var shuffleButton: UIButton!
  @IBOutlet
  weak var repeatButton: UIButton!
  @IBOutlet
  weak var autoplayButton: UIButton!

  @IBOutlet
  weak var autoplayTrailingConstraint: NSLayoutConstraint!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
    self.player = appDelegate.player
    player.addNotifier(notifier: self)
    self.playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    usesPlayerLayout = toWorkOnRootView != nil
    playerHandler?.usesGlassModeButtons = usesPlayerLayout
    if usesPlayerLayout {
      isOpaque = false
      backgroundColor = .clear
      queueNameLabel.backgroundColor = .clear
      contextNameLabel.backgroundColor = .clear
      NSLayoutConstraint.deactivate(constraints)
      let views: [UIView?] = [queueNameLabel, contextNameLabel, shuffleButton, repeatButton, autoplayButton]
      for view in views {
        guard let view else { continue }
        NSLayoutConstraint.deactivate(view.constraints)
        view.translatesAutoresizingMaskIntoConstraints = true
      }
      queueNameLabel.text = "Playing next".localized
      queueNameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
      queueNameLabel.textColor = .white
      contextNameLabel.font = .systemFont(ofSize: 12)
      contextNameLabel.textColor = .white.withAlphaComponent(0.55)
      shuffleButton.accessibilityLabel = "Shuffle".localized
      repeatButton.accessibilityLabel = "Repeat".localized
      autoplayButton.accessibilityLabel = "Autoplay".localized
      for button in [shuffleButton, repeatButton, autoplayButton].compactMap({ $0 }) {
        button.configurationUpdateHandler = { [weak self] button in
          Self.applyModeStyle(to: button)
          self?.rootView?.updateQueueModeBackgrounds()
        }
      }
    }
    contextNameLabel.applyAmperfyStyle()
    refresh()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard usesPlayerLayout else { return }
    let width = max(0, bounds.width - 16)
    let itemWidth = (width - 16) / 3
    for (index, button) in [shuffleButton, repeatButton, autoplayButton].enumerated() {
      button?.frame = CGRect(x: 8 + CGFloat(index) * (itemWidth + 8), y: 0,
                             width: itemWidth, height: 44)
    }
    queueNameLabel.frame = CGRect(x: 8, y: 54, width: width, height: 22)
    contextNameLabel.frame = CGRect(x: 8, y: 77, width: width, height: 16)
    rootView?.updateQueueModeBackgrounds()
  }

  private func styleModeButtons() {
    guard usesPlayerLayout else { return }
    for button in [shuffleButton, repeatButton, autoplayButton] {
      guard let button else { continue }
      Self.applyModeStyle(to: button)
    }
  }

  private static func applyModeStyle(to button: UIButton) {
    let image = button.configuration?.image
    var config = UIButton.Configuration.playerQueueMode(isSelected: button.isSelected)
    config.image = image
    button.configuration = config
  }

  func refresh() {
    contextNameLabel.text = "\(player.contextName)"
    refreshCurrentlyPlayingInfo()
    configureAutoplayButtonPosition()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    playerHandler?.refreshAutoplayButton(autoplayButton: autoplayButton)
    styleModeButtons()
  }

  func configureAutoplayButtonPosition() {
    guard !usesPlayerLayout else { return }
    autoplayTrailingConstraint.isActive = false
    #if targetEnvironment(macCatalyst)
      if appDelegate.isShowingMiniPlayer {
        autoplayTrailingConstraint = autoplayButton.trailingAnchor.constraint(
          equalTo: shuffleButton.leadingAnchor,
          constant: -8.0
        )
      } else {
        autoplayTrailingConstraint = autoplayButton.trailingAnchor.constraint(
          equalTo: safeAreaLayoutGuide.trailingAnchor,
          constant: -8.0
        )
      }
    #else
      autoplayTrailingConstraint = autoplayButton.trailingAnchor.constraint(
        equalTo: shuffleButton.leadingAnchor,
        constant: -8.0
      )
    #endif
    NSLayoutConstraint.activate([
      autoplayTrailingConstraint,
    ])
  }

  func refreshCurrentlyPlayingInfo() {
    switch player.playerMode {
    case .music:
      repeatButton.isHidden = false
      shuffleButton.isHidden = false
      autoplayButton.isHidden = false
    case .podcast:
      repeatButton.isHidden = true
      shuffleButton.isHidden = true
      autoplayButton.isHidden = true
    }
  }

  @IBAction
  func pressedShuffle(_ sender: Any) {
    playerHandler?.shuffleButtonPushed()
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    styleModeButtons()
    rootView?.scrollToCurrentlyPlayingRow()
  }

  @IBAction
  func pressedRepeat(_ sender: Any) {
    playerHandler?.repeatButtonPushed()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    styleModeButtons()
  }

  @IBAction
  func pressedAutoplay(_ sender: Any) {
    playerHandler?.autoplayButtonPushed()
    playerHandler?.refreshAutoplayButton(autoplayButton: autoplayButton)
    styleModeButtons()
  }
}

// MARK: MusicPlayable

extension ContextQueueNextSectionHeader: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {}

  func didPause() {}

  func didStopPlaying() {
    refreshCurrentlyPlayingInfo()
  }

  func didElapsedTimeChange() {}

  func didPlaylistChange() {
    refresh()
  }

  func didArtworkChange() {}

  func didShuffleChange() {
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    styleModeButtons()
  }

  func didRepeatChange() {
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    playerHandler?.refreshAutoplayButton(autoplayButton: autoplayButton)
    styleModeButtons()
  }

  func didPlaybackRateChange() {}
}

// The controls stay in UITableView so its pan, drag and accessibility behavior
// remain native. Their glass samples the player background in a sibling layer;
// the table's compositing group suppresses glass placed inside its content.
final class QueueModeGlassBackground: UIView {
  private let materials = (0..<3).map { _ in UIVisualEffectView(effect: nil) }
  private var states = [Int?](repeating: nil, count: 3)

  init() {
    super.init(frame: .zero)
    isOpaque = false
    clipsToBounds = true
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    for material in materials {
      material.cornerConfiguration = .capsule()
      addSubview(material)
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(buttons: [UIButton], table: UITableView) {
    frame = table.frame
    alpha = table.alpha
    isHidden = table.isHidden || buttons.allSatisfy(\.isHidden)
    for (index, button) in buttons.enumerated() {
      let material = materials[index]
      material.frame = button.convert(button.bounds, to: self)
      material.isHidden = button.isHidden
      let state = (button.isSelected ? 1 : 0) + (button.isHighlighted ? 2 : 0)
      if states[index] != state {
        let glass = UIGlassEffect(style: .regular)
        if button.isSelected {
          glass.tintColor = .white.withAlphaComponent(button.isHighlighted ? 0.85 : 0.7)
        } else if button.isHighlighted {
          glass.tintColor = .white.withAlphaComponent(0.18)
        }
        material.effect = glass
        states[index] = state
      }
    }
  }
}
