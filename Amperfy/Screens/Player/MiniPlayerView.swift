//
//  MiniPlayerView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 31.07.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import MediaPlayer
import UIKit

// MARK: - MiniPlayerView

class MiniPlayerView: UIView, UIGestureRecognizerDelegate {
  private var player: PlayerFacade
  private var playerHandler: PlayerUIHandler?

  private var hoverOverlayView: UIView?
  private var trackPan: UIPanGestureRecognizer?
  private var expandPan: UIPanGestureRecognizer?
  private weak var expandingPlayer: PopupPlayerVC?
  private var accessoryBottomInsetConstraint: NSLayoutConstraint?
  private var trackViewport: UIView?
  private var trackContent: UIView?
  private var trackDragOverlay: UIView?
  private var trackDragContent: UIView?
  private var trackDragSong: AbstractPlayable?
  private(set) var trackDragPreviousSong: AbstractPlayable?
  private(set) var trackDragNextSong: AbstractPlayable?
  private var previousTrackPreview: UIView?
  private var nextTrackPreview: UIView?
  private var trackDragAnimator: UIViewPropertyAnimator?
  private(set) var trackDragTranslation: CGFloat = 0

  static let mediumButtonSize: CGFloat = 20.0

  #if targetEnvironment(macCatalyst) // ok
    var airplayVolume: MPVolumeView?
  #endif

  fileprivate lazy var artworkOverlay: UIView = {
    let view = UIView()
    view.backgroundColor = .black.withAlphaComponent(0.4)
    view.isHidden = true

    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .white
    imageView.image = .miniPlayer.withRenderingMode(.alwaysTemplate)

    view.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      imageView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
      imageView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.8),
    ])

    return view
  }()

  private(set) lazy var artworkImage: LibraryEntityImage = {
    let imageView = LibraryEntityImage(frame: .zero)
    imageView.backgroundColor = .clear
    #if targetEnvironment(macCatalyst) // ok
      artworkOverlay.translatesAutoresizingMaskIntoConstraints = false
      imageView.addSubview(artworkOverlay)
      NSLayoutConstraint.activate([
        artworkOverlay.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
        artworkOverlay.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
        artworkOverlay.widthAnchor.constraint(equalTo: imageView.widthAnchor),
        artworkOverlay.heightAnchor.constraint(equalTo: imageView.heightAnchor),
      ])

      imageView.isUserInteractionEnabled = true
      let miniPlayerHoverGesture = UIHoverGestureRecognizer(
        target: self,
        action: #selector(artworkHovered(_:))
      )
      let miniPlayerTapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(artworkClicked(_:))
      )
      imageView.addGestureRecognizer(miniPlayerTapGesture)
      imageView.addGestureRecognizer(miniPlayerHoverGesture)
    #endif
    return imageView
  }()

  fileprivate lazy var titleLabel: UILabel = {
    let label = MarqueeLabel(frame: .zero)
    label.applyAmperfyStyle()
    label.textAlignment = .center
    label.backgroundColor = .clear
    label.numberOfLines = 1
    label.textColor = .label
    return label
  }()

  fileprivate lazy var subtitleLabel: UILabel = {
    let label = MarqueeLabel(frame: .zero)
    label.applyAmperfyStyle()
    label.backgroundColor = .clear
    label.textAlignment = .center
    label.numberOfLines = 1
    label.textColor = .secondaryLabel
    return label
  }()

  fileprivate lazy var timeSlider: SeekableTimeSlider = {
    let slider = SeekableTimeSlider(frame: .zero)
    slider.preferredBehavioralStyle = .pad
    return slider
  }()

  @objc
  func artworkHovered(_ sender: UIHoverGestureRecognizer) {
    switch sender.state {
    case .began:
      artworkOverlay.isHidden = false
    case .cancelled, .ended, .failed:
      artworkOverlay.isHidden = true
    default:
      break
    }
  }

  @objc
  func artworkClicked(_ sender: UITapGestureRecognizer) {
    switch sender.state {
    case .ended:
      appDelegate.closeMainWindow()
      appDelegate.showMiniPlayer()
    default:
      break
    }
  }

  @objc
  func timeSliderChanged(_ slider: UISlider) {
    playerHandler?.timeSliderChanged(timeSlider: timeSlider)
  }

  @IBAction
  func timeSliderIsChanging(_ sender: Any) {
    playerHandler?.timeSliderIsChanging(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel
    )
  }

  fileprivate lazy var elapsedTimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textColor = .secondaryLabel
    label.font = .systemFont(ofSize: 12.0)
    return label
  }()

  fileprivate lazy var remainingTimeLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.textAlignment = .right
    label.textColor = .secondaryLabel
    label.font = .systemFont(ofSize: 12.0)
    return label
  }()

  fileprivate lazy var liveLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.text = "LIVE".localized
    label.font = .systemFont(ofSize: 12.0)
    label.textAlignment = .center
    return label
  }()

  fileprivate lazy var audioInfoLabel: UILabel = {
    let label = UILabel(frame: .zero)
    label.font = .systemFont(ofSize: 12.0)
    return label
  }()

  fileprivate lazy var playTypeIcon: UIImageView = {
    let imageView = UIImageView(frame: .zero)
    imageView.tintColor = .secondaryLabel
    return imageView
  }()

  fileprivate lazy var moreButton: UIButton = {
    let button = UIButton()
    button.setImage(
      .ellipsis.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
        .withRenderingMode(.alwaysTemplate),
      for: .normal
    )
    button.imageView?.tintColor = .label
    button.showsMenuAsPrimaryAction = true
    return button
  }()

  fileprivate lazy var playButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .play
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.playButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.playButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func playButtonPushed(_ sender: Any) {
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  fileprivate lazy var previousButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .backwardFill.withConfiguration(UIImage.SymbolConfiguration(scale: .large))
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.previousButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    playerHandler?.previousButtonPushed()
  }

  fileprivate lazy var nextButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .forwardFill.withConfiguration(UIImage.SymbolConfiguration(scale: .large))
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.nextButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    playerHandler?.nextButtonPushed()
  }

  fileprivate lazy var repeatButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .repeatMenu.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(Self.repeatButtonPushed), for: .touchUpInside)
    button
      .cornerConfiguration =
      .corners(radius: UICornerRadius(floatLiteral: Self.mediumButtonSize / 2))
    return button
  }()

  @IBAction
  func repeatButtonPushed(_ sender: Any) {
    playerHandler?.repeatButtonPushed()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }

  fileprivate lazy var shuffleButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .shuffle.withConfiguration(UIImage.SymbolConfiguration(scale: .medium))
    let button = UIButton(configuration: config)
    button.addTarget(self, action: #selector(Self.shuffleButtonPushed), for: .touchUpInside)
    button
      .cornerConfiguration =
      .corners(radius: UICornerRadius(floatLiteral: Self.mediumButtonSize / 2))
    return button
  }()

  @IBAction
  func shuffleButtonPushed(_ sender: Any) {
    playerHandler?.shuffleButtonPushed()
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  fileprivate lazy var lyricsButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .lyrics
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.lyricsPressed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func lyricsPressed() {
    appDelegate.storage.settings.user.isPlayerLyricsDisplayed.toggle()
    if appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
      appDelegate.storage.settings.user.playerDisplayStyle = .large
    }
    playerHandler?.refreshDisplayLyrisButton(displayLyricsButton: lyricsButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)

    guard let host = AppDelegate.mainWindowHostVC as? SplitVC else { return }
    host.displayOrHideInspector()
  }

  fileprivate lazy var playlistButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .playlist
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.playlistPressed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func playlistPressed() {
    appDelegate.storage.settings.user.playerDisplayStyle.switchToNextStyle()
    if appDelegate.storage.settings.user.playerDisplayStyle == .compact {
      appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
    }
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)
    playerHandler?.refreshDisplayLyrisButton(displayLyricsButton: lyricsButton)

    guard let host = AppDelegate.mainWindowHostVC as? SplitVC else { return }
    host.displayOrHideInspector()
  }

  fileprivate lazy var airplayButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .airplayaudio
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.airplayButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func airplayButtonPushed(_ sender: UIButton) {
    #if targetEnvironment(macCatalyst) // ok
      playerHandler?.airplayButtonPushed(
        rootView: self,
        airplayButton: airplayButton,
        airplayVolume: airplayVolume
      )
    #endif
  }

  fileprivate lazy var volumeButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.image = .volumeMax
      .withConfiguration(
        UIImage
          .SymbolConfiguration(pointSize: PlayerUIHandler.bigButtonImagePointSize)
      )
    let button = UIButton(configuration: config)
    button.tintColor = .label
    button.addTarget(self, action: #selector(Self.volumeButtonPushed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func volumeButtonPushed(_ sender: UIButton) {
    showVolumeSliderMenu()
  }

  public lazy var infoView: UIView = {
    let view = UIView(frame: .zero)

    self.titleLabel.translatesAutoresizingMaskIntoConstraints = false
    (subtitleLabel).translatesAutoresizingMaskIntoConstraints = false
    (artworkImage).translatesAutoresizingMaskIntoConstraints = false
    (moreButton).translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(titleLabel)
    view.addSubview(subtitleLabel)
    view.addSubview(artworkImage)
    view.addSubview(moreButton)

    NSLayoutConstraint.activate([
      artworkImage.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
      artworkImage.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
      artworkImage.widthAnchor.constraint(equalTo: artworkImage.heightAnchor),
      artworkImage.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      self.titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
      self.titleLabel.heightAnchor.constraint(equalTo: self.subtitleLabel.heightAnchor),
      self.titleLabel.leadingAnchor.constraint(equalTo: artworkImage.trailingAnchor, constant: 10),
      self.titleLabel.trailingAnchor.constraint(
        equalTo: self.moreButton.leadingAnchor,
        constant: 0
      ),
      self.subtitleLabel.topAnchor.constraint(equalTo: self.titleLabel.bottomAnchor),
      self.subtitleLabel.leadingAnchor.constraint(
        equalTo: self.artworkImage.trailingAnchor,
        constant: 10
      ),
      self.subtitleLabel.trailingAnchor.constraint(
        equalTo: self.moreButton.leadingAnchor,
        constant: 0
      ),
      self.subtitleLabel.bottomAnchor.constraint(
        equalTo: view.bottomAnchor,
        constant: -3
      ),

      self.moreButton.widthAnchor.constraint(equalToConstant: 30),
      self.moreButton.heightAnchor.constraint(equalToConstant: 30),
      self.moreButton.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: 0
      ),
      self.moreButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])

    return view
  }()

  public lazy var sliderAndinfoView: UIView = {
    let view = UIView(frame: .zero)

    let hoverContainer = UIView()

    self.infoView.translatesAutoresizingMaskIntoConstraints = false
    (timeSlider).translatesAutoresizingMaskIntoConstraints = false
    (liveLabel).translatesAutoresizingMaskIntoConstraints = false
    (hoverContainer).translatesAutoresizingMaskIntoConstraints = false

    let hoverGesture = UIHoverGestureRecognizer(
      target: self,
      action: #selector(handleHoverContainerHover(_:))
    )
    hoverContainer.addGestureRecognizer(hoverGesture)

    hoverContainer.addSubview(timeSlider)
    view.addSubview(infoView)
    view.addSubview(liveLabel)
    view.addSubview(hoverContainer)

    NSLayoutConstraint.activate([
      timeSlider.bottomAnchor.constraint(equalTo: hoverContainer.bottomAnchor, constant: -5),
      timeSlider.leadingAnchor.constraint(equalTo: hoverContainer.leadingAnchor),
      timeSlider.trailingAnchor.constraint(
        equalTo: hoverContainer.trailingAnchor,
        constant: 0
      ),
      timeSlider.heightAnchor.constraint(equalToConstant: 3),

      liveLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor, constant: 0),
      liveLabel.centerYAnchor.constraint(equalTo: timeSlider.centerYAnchor, constant: 0),

      infoView.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
      infoView.bottomAnchor.constraint(equalTo: timeSlider.topAnchor, constant: -5),
      infoView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
      infoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

      hoverContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: 0),
      hoverContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hoverContainer.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: 0
      ),
      hoverContainer.heightAnchor.constraint(equalToConstant: 17),
    ])

    return view
  }()

  public lazy var leadingButtonsView: UIView = {
    NSLayoutConstraint.activate([
      shuffleButton.heightAnchor.constraint(equalToConstant: Self.mediumButtonSize),
      shuffleButton.widthAnchor.constraint(equalTo: shuffleButton.heightAnchor, constant: 3),
      repeatButton.heightAnchor.constraint(equalToConstant: Self.mediumButtonSize),
      repeatButton.widthAnchor.constraint(equalTo: repeatButton.heightAnchor, constant: 3),
    ])

    self.shuffleButton.translatesAutoresizingMaskIntoConstraints = false
    self.previousButton.translatesAutoresizingMaskIntoConstraints = false
    self.playButton.translatesAutoresizingMaskIntoConstraints = false
    self.nextButton.translatesAutoresizingMaskIntoConstraints = false
    self.repeatButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [
      shuffleButton,
      previousButton,
      playButton,
      nextButton,
      repeatButton,
    ])
    stack.axis = .horizontal
    stack.distribution = .equalSpacing
    stack.alignment = .center
    return stack
  }()

  public lazy var trailingButtonsView: UIStackView = {
    self.lyricsButton.translatesAutoresizingMaskIntoConstraints = false
    self.playlistButton.translatesAutoresizingMaskIntoConstraints = false
    self.airplayButton.translatesAutoresizingMaskIntoConstraints = false
    self.volumeButton.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [
      lyricsButton,
      playlistButton,
      airplayButton,
      volumeButton,
    ])
    stack.axis = .horizontal
    stack.distribution = .equalSpacing
    stack.alignment = .center
    return stack
  }()

  public func refreshTrailingButtons() {
    guard let playerHandler else { return }
    if playerHandler.isLyricsButtonAllowedToDisplay {
      lyricsButton.isHidden = false
      trailingButtonsViewWidthConstraint?.constant = 140
    } else {
      lyricsButton.isHidden = true
      trailingButtonsViewWidthConstraint?.constant = 100
    }
  }

  func refreshMoreButton() {
    let currentlyPlaying = player.currentlyPlaying
    let hasPlayable = currentlyPlaying != nil

    moreButton.isEnabled = hasPlayable

    if let currentlyPlaying,
       let hostVC = AppDelegate.mainWindowHostVC as? UIViewController {
      moreButton.menu = UIMenu.lazyMenu {
        EntityPreviewActionBuilder(container: currentlyPlaying, on: hostVC).createMenuActions()
      }
    }
  }

  private var trailingButtonsViewWidthConstraint: NSLayoutConstraint?

  init(player: PlayerFacade) {
    self.player = player

    #if targetEnvironment(macCatalyst) // ok
      self.airplayVolume = MPVolumeView(frame: .zero)
      airplayVolume!.showsVolumeSlider = false
      airplayVolume!.isHidden = true
    #endif

    super.init(frame: .zero)
    #if targetEnvironment(macCatalyst) // ok
      addSubview(airplayVolume!)
    #endif

    player.addNotifier(notifier: self)

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refreshPlayer()
      }
    )

    registerForTraitChanges([UITraitTabAccessoryEnvironment.self]) { (
      self: Self,
      previousTraitCollection: UITraitCollection
    ) in
      self.refreshForTabAccessoryTraitChange()
      self.tabAccessoryTraitChangeCB?()
    }
  }

  public var tabAccessoryTraitChangeCB: VoidFunctionCallback?

  private func refreshForTabAccessoryTraitChange() {
    resetTrackDrag()
    let isInline = traitCollection.tabAccessoryEnvironment == .inline
    setAccessoryBottomInset(isInline ? 0 : 8)
    playButtonTrailingConstraint?.isActive = false
    if isInline {
      nextButton.isHidden = true
      playButtonTrailingConstraint = playButton.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -10
      )
    } else {
      nextButton.isHidden = false
      playButtonTrailingConstraint = playButton.trailingAnchor.constraint(
        equalTo: nextButton.leadingAnchor,
        constant: -5
      )
    }
    playButtonTrailingConstraint?.isActive = true
  }

  public func configureForMac() {
    playerHandler = PlayerUIHandler(player: player, style: .miniPlayerMac)
    sliderAndinfoView.translatesAutoresizingMaskIntoConstraints = false
    leadingButtonsView.translatesAutoresizingMaskIntoConstraints = false
    trailingButtonsView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(sliderAndinfoView)
    addSubview(leadingButtonsView)
    addSubview(trailingButtonsView)

    trailingButtonsViewWidthConstraint = trailingButtonsView.widthAnchor
      .constraint(equalToConstant: 160)

    timeSlider.addTarget(self, action: #selector(timeSliderChanged(_:)), for: .valueChanged)
    timeSlider.addTarget(self, action: #selector(timeSliderIsChanging(_:)), for: .touchDragInside)
    timeSlider.addTarget(self, action: #selector(timeSliderIsChanging(_:)), for: .touchDragOutside)

    NSLayoutConstraint.activate([
      leadingButtonsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      leadingButtonsView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      leadingButtonsView.bottomAnchor.constraint(equalTo: bottomAnchor),
      leadingButtonsView.widthAnchor.constraint(equalToConstant: 150),

      sliderAndinfoView.leadingAnchor.constraint(
        equalTo: leadingButtonsView.trailingAnchor,
        constant: 10
      ),
      sliderAndinfoView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      sliderAndinfoView.bottomAnchor.constraint(equalTo: bottomAnchor),
      sliderAndinfoView.trailingAnchor.constraint(
        equalTo: trailingButtonsView.leadingAnchor,
        constant: -10
      ),

      trailingButtonsView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      trailingButtonsView.bottomAnchor.constraint(equalTo: bottomAnchor),
      trailingButtonsViewWidthConstraint!,
      trailingButtonsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
    refreshPlayer()
  }

  public func configureForiOS() {
    playerHandler = PlayerUIHandler(player: player, style: .miniPlayeriOS)
    titleLabel.textAlignment = .natural
    subtitleLabel.textAlignment = .natural
    artworkImage.layer.cornerRadius = 7
    artworkImage.layer.cornerCurve = .continuous
    artworkImage.clipsToBounds = true
    timeSlider.minimumTrackTintColor = .secondaryLabel
    timeSlider.maximumTrackTintColor = .clear
    let miniPlayerGotTouchedView = UIView()
    miniPlayerGotTouchedView.clipsToBounds = true
    let content = UIView()
    content.isUserInteractionEnabled = false
    content.translatesAutoresizingMaskIntoConstraints = false
    miniPlayerGotTouchedView.addSubview(content)
    trackViewport = miniPlayerGotTouchedView
    trackContent = content
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(miniPlayerGotTouched))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTrackPan(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    trackPan = pan
    miniPlayerGotTouchedView.addGestureRecognizer(pan)
    tapGesture.require(toFail: pan)
    let expandPan = UIPanGestureRecognizer(target: self, action: #selector(handleExpandPan(_:)))
    expandPan.maximumNumberOfTouches = 1
    expandPan.delegate = self
    self.expandPan = expandPan
    miniPlayerGotTouchedView.addGestureRecognizer(expandPan)
    tapGesture.require(toFail: expandPan)
    miniPlayerGotTouchedView.addGestureRecognizer(tapGesture)
    miniPlayerGotTouchedView.isAccessibilityElement = true
    miniPlayerGotTouchedView.accessibilityLabel = "Open Now Playing".localized
    miniPlayerGotTouchedView.accessibilityTraits = .button

    miniPlayerGotTouchedView.translatesAutoresizingMaskIntoConstraints = false
    artworkImage.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    timeSlider.translatesAutoresizingMaskIntoConstraints = false
    liveLabel.translatesAutoresizingMaskIntoConstraints = false
    playButton.translatesAutoresizingMaskIntoConstraints = false
    nextButton.translatesAutoresizingMaskIntoConstraints = false

    addSubview(miniPlayerGotTouchedView)
    content.addSubview(artworkImage)
    content.addSubview(titleLabel)
    content.addSubview(subtitleLabel)
    addSubview(timeSlider)
    addSubview(liveLabel)
    addSubview(playButton)
    addSubview(nextButton)

    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: miniPlayerGotTouchedView.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: miniPlayerGotTouchedView.trailingAnchor),
      content.topAnchor.constraint(equalTo: miniPlayerGotTouchedView.topAnchor),
      content.bottomAnchor.constraint(equalTo: miniPlayerGotTouchedView.bottomAnchor),
      miniPlayerGotTouchedView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      miniPlayerGotTouchedView.heightAnchor.constraint(equalTo: heightAnchor),
      miniPlayerGotTouchedView.bottomAnchor.constraint(equalTo: bottomAnchor),
      miniPlayerGotTouchedView.trailingAnchor.constraint(
        equalTo: playButton.leadingAnchor,
        constant: -8
      ),

      timeSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      timeSlider.heightAnchor.constraint(equalToConstant: 3),
      timeSlider.bottomAnchor.constraint(equalTo: bottomAnchor),
      timeSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

      liveLabel.centerXAnchor.constraint(equalTo: timeSlider.centerXAnchor, constant: 0),
      liveLabel.centerYAnchor.constraint(equalTo: timeSlider.centerYAnchor, constant: 0),
      liveLabel.widthAnchor.constraint(equalToConstant: 0),
      liveLabel.heightAnchor.constraint(equalTo: liveLabel.widthAnchor),

      artworkImage.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      artworkImage.bottomAnchor.constraint(equalTo: timeSlider.topAnchor, constant: -4),
      artworkImage.widthAnchor.constraint(equalTo: artworkImage.heightAnchor),
      artworkImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),

      titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      titleLabel.bottomAnchor.constraint(equalTo: playButton.centerYAnchor, constant: 1),
      titleLabel.leadingAnchor.constraint(equalTo: artworkImage.trailingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),

      subtitleLabel.topAnchor.constraint(equalTo: playButton.centerYAnchor, constant: 1),
      subtitleLabel.bottomAnchor.constraint(equalTo: timeSlider.topAnchor, constant: -5),
      subtitleLabel.leadingAnchor.constraint(equalTo: artworkImage.trailingAnchor, constant: 12),
      subtitleLabel.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -8),

      playButton.centerYAnchor.constraint(equalTo: artworkImage.centerYAnchor, constant: 0),
      playButton.widthAnchor.constraint(equalToConstant: 44),
      playButton.heightAnchor.constraint(equalTo: playButton.widthAnchor),
      // playButton trailing constraint is depending on tab bar bottom accessory

      nextButton.centerYAnchor.constraint(equalTo: artworkImage.centerYAnchor, constant: 0),
      nextButton.widthAnchor.constraint(equalToConstant: 44),
      nextButton.heightAnchor.constraint(equalTo: nextButton.widthAnchor),
      nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
    refreshPlayer()
    refreshForTraitChange(horizontalSizeClass: traitCollection.horizontalSizeClass)
    refreshForTabAccessoryTraitChange()
  }

  @objc
  private func handleTrackPan(_ gesture: UIPanGestureRecognizer) {
    switch gesture.state {
    case .began: beginTrackDrag()
    case .changed: updateTrackDrag(translation: gesture.translation(in: self).x)
    case .ended:
      updateTrackDrag(translation: gesture.translation(in: self).x)
      endTrackDrag(velocity: gesture.velocity(in: self).x)
    case .cancelled, .failed: endTrackDrag(velocity: 0, cancelled: true)
    default: break
    }
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === expandPan, let pan = gestureRecognizer as? UIPanGestureRecognizer {
      let velocity = pan.velocity(in: self)
      return velocity.y < -abs(velocity.x) && trackDragAnimator == nil &&
        (AppDelegate.mainWindowHostVC as? UIViewController)?.presentedViewController == nil
    }
    guard gestureRecognizer === trackPan, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: self)
    return player.currentlyPlaying != nil && trackDragAnimator == nil && abs(velocity.x) > abs(velocity.y)
  }

  func beginTrackDrag() {
    resetTrackDrag()
    guard let song = player.currentlyPlaying,
          let overlay = trackViewport, let content = trackContent else { return }
    layoutIfNeeded()
    // Move the live content inside its viewport. Snapshot substitutes do not
    // reliably retain the system tab accessory's material/vibrancy rendering.
    trackDragOverlay = overlay
    trackDragContent = content
    trackDragSong = song
    trackDragPreviousSong = adjacentPlayable(isNext: false)
    trackDragNextSong = adjacentPlayable(isNext: true)
    if let previous = trackDragPreviousSong {
      previousTrackPreview = makeTrackPreview(for: previous, in: overlay)
    }
    if let next = trackDragNextSong {
      nextTrackPreview = makeTrackPreview(for: next, in: overlay)
    }
    positionTrackPages(at: 0)
  }

  private func adjacentPlayable(isNext: Bool) -> AbstractPlayable? {
    if isNext {
      if player.userQueueCount > 0 { return player.getUserQueueItems(from: 0, to: 0).first }
      if player.nextQueueCount > 0 { return player.getNextQueueItems(from: 0, to: 0).first }
      if player.repeatMode == .all, player.prevQueueCount > 0 {
        return player.getPrevQueueItems(from: 0, to: 0).first
      }
    } else {
      if player.prevQueueCount > 0 {
        let index = player.prevQueueCount - 1
        return player.getPrevQueueItems(from: index, to: index).first
      }
      if player.repeatMode == .all, player.nextQueueCount > 0 {
        let index = player.nextQueueCount - 1
        return player.getNextQueueItems(from: index, to: index).first
      }
    }
    return nil
  }

  private func makeTrackPreview(for song: AbstractPlayable, in viewport: UIView) -> UIView {
    let page = UIView(frame: viewport.bounds)
    page.isUserInteractionEnabled = false
    page.clipsToBounds = true
    let cover = LibraryEntityImage(frame: .zero)
    cover.frame = artworkImage.convert(artworkImage.bounds, to: viewport)
    cover.layer.cornerRadius = artworkImage.layer.cornerRadius
    cover.layer.cornerCurve = .continuous
    cover.clipsToBounds = true
    page.addSubview(cover)
    cover.displayAndUpdate(entity: song)
    for (source, text) in [(titleLabel, song.title), (subtitleLabel, song.creatorName)] {
      let label = UILabel(frame: source.convert(source.bounds, to: viewport))
      label.font = source.font
      label.textColor = source.textColor
      label.textAlignment = source.textAlignment
      label.lineBreakMode = .byTruncatingTail
      label.text = text
      page.addSubview(label)
    }
    viewport.addSubview(page)
    return page
  }

  private func positionTrackPages(at translation: CGFloat) {
    guard let viewport = trackDragOverlay else { return }
    let width = viewport.bounds.width
    trackDragContent?.transform = CGAffineTransform(translationX: translation, y: 0)
    previousTrackPreview?.transform = CGAffineTransform(translationX: translation - width, y: 0)
    nextTrackPreview?.transform = CGAffineTransform(translationX: translation + width, y: 0)
  }

  func updateTrackDrag(translation: CGFloat) {
    guard let overlay = trackDragOverlay else { return }
    let hasNeighbor = translation < 0 ? trackDragNextSong != nil : trackDragPreviousSong != nil
    let distance = hasNeighbor ? translation : translation * 0.22
    trackDragTranslation = min(overlay.bounds.width, max(-overlay.bounds.width, distance))
    positionTrackPages(at: trackDragTranslation)
  }

  func endTrackDrag(velocity: CGFloat, cancelled: Bool = false) {
    guard let overlay = trackDragOverlay, trackDragContent != nil else { return }
    let distance = trackDragTranslation
    let threshold = min(92, overlay.bounds.width * 0.30)
    let pullingBack = distance * velocity < 0 && abs(velocity) > 150
    let isNext = distance < 0
    let target = isNext ? trackDragNextSong : trackDragPreviousSong
    let commit = !cancelled && !pullingBack && abs(distance) >= threshold && trackDragSong == player.currentlyPlaying && target != nil && target == adjacentPlayable(isNext: isNext)
    let animator = UIViewPropertyAnimator(duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18, curve: .easeOut) { [weak self] in
      self?.positionTrackPages(at: commit ? (isNext ? -overlay.bounds.width : overlay.bounds.width) : 0)
    }
    trackDragAnimator = animator
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      let shouldSwitch = position == .end && commit && self.trackDragSong == self.player.currentlyPlaying && target == self.adjacentPlayable(isNext: isNext)
      self.trackDragAnimator = nil
      if shouldSwitch {
        if isNext { self.player.playNext() } else { self.player.playPrevious() }
      }
      self.resetTrackDrag()
      guard shouldSwitch else { return }
      self.refreshPlayer()
    }
    animator.startAnimation()
  }

  private func resetTrackDrag() {
    trackDragAnimator?.stopAnimation(true)
    trackDragAnimator = nil
    trackContent?.transform = .identity
    previousTrackPreview?.removeFromSuperview()
    nextTrackPreview?.removeFromSuperview()
    previousTrackPreview = nil
    nextTrackPreview = nil
    trackDragPreviousSong = nil
    trackDragNextSong = nil
    trackDragOverlay = nil
    trackDragContent = nil
    trackDragSong = nil
    trackDragTranslation = 0
    [artworkImage, titleLabel, subtitleLabel].forEach { $0.alpha = 1 }
  }

  public func refreshForTraitChange(horizontalSizeClass: UIUserInterfaceSizeClass) {
    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
  }

  private var playButtonTrailingConstraint: NSLayoutConstraint?

  @objc
  private func miniPlayerGotTouched(_ recognizer: UITapGestureRecognizer) {
    openPlayerView()
  }

  public func openPlayerView(completion: (() -> ())? = nil) {
    guard let hostVC = AppDelegate.mainWindowHostVC as? UIViewController,
          hostVC.presentedViewController == nil else { return }
    let popupPlayer = PopupPlayerVC()
    popupPlayer.configurePresentation(sourceArtwork: artworkImage)
    hostVC.present(popupPlayer, animated: true, completion: completion)
  }

  @objc private func handleExpandPan(_ pan: UIPanGestureRecognizer) {
    let translation = -pan.translation(in: window).y
    switch pan.state {
    case .began: beginPlayerExpansion()
    case .changed: updatePlayerExpansion(translation: translation)
    case .ended:
      endPlayerExpansion(translation: translation, velocity: -pan.velocity(in: window).y)
    case .cancelled, .failed:
      endPlayerExpansion(translation: 0, velocity: 0, cancelled: true)
    default: break
    }
  }

  func beginPlayerExpansion() {
    guard let hostVC = AppDelegate.mainWindowHostVC as? UIViewController,
          hostVC.presentedViewController == nil else { return }
    let popup = PopupPlayerVC()
    popup.configurePresentation(sourceArtwork: artworkImage)
    let interaction = UIPercentDrivenInteractiveTransition()
    interaction.timingCurve = UISpringTimingParameters(dampingRatio: UIAccessibility.isReduceMotionEnabled ? 1 : 0.74)
    popup.artworkTransition.presentationInteraction = interaction
    expandingPlayer = popup
    hostVC.present(popup, animated: true)
  }

  func updatePlayerExpansion(translation: CGFloat) {
    let distance = max((window?.bounds.height ?? 800) * 0.6, 1)
    expandingPlayer?.artworkTransition.presentationInteraction?.update(min(0.99, max(0, translation / distance)))
  }

  func endPlayerExpansion(translation: CGFloat, velocity: CGFloat, cancelled: Bool = false) {
    guard let interaction = expandingPlayer?.artworkTransition.presentationInteraction else { return }
    let finish = !cancelled && velocity > -100 && (translation > 70 || (translation > 12 && velocity > 550))
    if finish { interaction.finish() } else { interaction.cancel() }
    expandingPlayer = nil
  }

  func setAccessoryBottomInset(_ inset: CGFloat) {
    guard accessoryBottomInsetConstraint?.constant != inset else { return }
    accessoryBottomInsetConstraint?.constant = inset
  }

  @objc
  private func handleHoverContainerHover(_ recognizer: UIHoverGestureRecognizer) {
    switch recognizer.state {
    case .began, .changed:
      if hoverOverlayView == nil {
        showHoverOverlay()
      }
    case .cancelled, .ended:
      hideHoverOverlay()
    default:
      break
    }
  }

  private func showHoverOverlay() {
    guard hoverOverlayView == nil, liveLabel.isHidden else { return }
    let overlay = createHoverOverlayView()
    addSubview(overlay)
    // Position overlay above artwork/title/subtitle area
    overlay.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      overlay.leadingAnchor.constraint(equalTo: infoView.leadingAnchor, constant: 0),
      overlay.trailingAnchor.constraint(equalTo: infoView.trailingAnchor, constant: 0),
      overlay.topAnchor.constraint(equalTo: infoView.topAnchor, constant: 0),
      overlay.heightAnchor.constraint(equalTo: infoView.heightAnchor),
    ])
    hoverOverlayView = overlay
  }

  private func hideHoverOverlay() {
    guard let overlay = hoverOverlayView else { return }
    overlay.removeFromSuperview()
    hoverOverlayView = nil
    infoView.layer.mask = nil
  }

  private func createHoverOverlayView() -> UIView {
    // make the info view transparent
    let mask = CAGradientLayer()
    mask.frame = infoView.bounds
    mask.colors = [
      UIColor.white.withAlphaComponent(0).cgColor,
      UIColor.white.withAlphaComponent(0).cgColor,
    ]
    mask.startPoint = CGPoint(x: 0.0, y: 0.0)
    mask.endPoint = CGPoint(x: 1.0, y: 0.0)
    mask.locations = [
      0.0, 1.0,
    ]
    infoView.layer.mask = mask

    let overlay = UIView()
    overlay.isUserInteractionEnabled = false

    let innerView = UIView(frame: .zero)
    innerView.addSubview(playTypeIcon)
    innerView.addSubview(audioInfoLabel)

    let outerView = UIView(frame: .zero)
    outerView.addSubview(innerView)

    overlay.addSubview(elapsedTimeLabel)
    overlay.addSubview(outerView)
    overlay.addSubview(remainingTimeLabel)

    innerView.translatesAutoresizingMaskIntoConstraints = false
    outerView.translatesAutoresizingMaskIntoConstraints = false
    elapsedTimeLabel.translatesAutoresizingMaskIntoConstraints = false
    playTypeIcon.translatesAutoresizingMaskIntoConstraints = false
    audioInfoLabel.translatesAutoresizingMaskIntoConstraints = false
    remainingTimeLabel.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      playTypeIcon.leadingAnchor.constraint(equalTo: innerView.leadingAnchor, constant: 0),
      playTypeIcon.centerYAnchor.constraint(equalTo: innerView.centerYAnchor, constant: 0),
      playTypeIcon.trailingAnchor.constraint(equalTo: audioInfoLabel.leadingAnchor, constant: -8),
      playTypeIcon.widthAnchor.constraint(equalToConstant: 14),
      playTypeIcon.heightAnchor.constraint(equalToConstant: 14),
      audioInfoLabel.centerYAnchor.constraint(equalTo: innerView.centerYAnchor, constant: 0),
      audioInfoLabel.trailingAnchor.constraint(equalTo: innerView.trailingAnchor, constant: 0),

      innerView.centerXAnchor.constraint(equalTo: outerView.centerXAnchor, constant: 0),
      innerView.centerYAnchor.constraint(equalTo: outerView.centerYAnchor, constant: 0),
      innerView.heightAnchor.constraint(equalTo: outerView.heightAnchor, constant: 0),

      outerView.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      outerView.heightAnchor.constraint(equalTo: overlay.heightAnchor, constant: 0),
      elapsedTimeLabel.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 0),
      elapsedTimeLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      elapsedTimeLabel.widthAnchor.constraint(equalToConstant: 60),
      outerView.leadingAnchor.constraint(equalTo: elapsedTimeLabel.trailingAnchor, constant: 0),
      outerView.trailingAnchor.constraint(equalTo: remainingTimeLabel.leadingAnchor, constant: 0),
      remainingTimeLabel.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: 0),
      remainingTimeLabel.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: 0),
      remainingTimeLabel.widthAnchor.constraint(equalToConstant: 60),
    ])
    return overlay
  }

  func refreshPlayer() {
    if let trackDragSong, trackDragSong != player.currentlyPlaying { resetTrackDrag() }
    titleLabel.textColor = .label
    subtitleLabel.textColor = .secondaryLabel
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
    playerHandler?.refreshArtwork(artworkImage: artworkImage)
    playerHandler?.refreshPlayButton(playButton)
    playerHandler?.refreshPrevNextButtons(previousButton: previousButton, nextButton: nextButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: playlistButton)
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
    refreshMoreButton()
    refreshTrailingButtons()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  public lazy var glassContainer: UIVisualEffectView = {
    let container = UIVisualEffectView()
    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = true
    container.effect = glassEffect
    container.cornerConfiguration = .capsule()
    container.contentView.addSubview(self)

    container.translatesAutoresizingMaskIntoConstraints = false
    self.translatesAutoresizingMaskIntoConstraints = false

    let bottomInset = container.bottomAnchor.constraint(equalTo: bottomAnchor)
    accessoryBottomInsetConstraint = bottomInset
    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      bottomInset,
    ])

    return container
  }()

  func showVolumeSliderMenu() {
    let popoverContentController = SliderMenuPopover()
    let sliderMenuView = popoverContentController.sliderMenuView
    sliderMenuView.frame = CGRect(x: 0, y: 0, width: 250, height: 50)

    sliderMenuView.slider.minimumValue = 0
    sliderMenuView.slider.maximumValue = 100
    sliderMenuView.slider.value = appDelegate.player.volume * 100

    sliderMenuView.sliderValueChangedCB = {
      self.appDelegate.player.volume = Float(sliderMenuView.slider.value) / 100.0
    }

    popoverContentController.modalPresentationStyle = .popover
    popoverContentController.preferredContentSize = sliderMenuView.frame.size

    if let popoverPresentationController = popoverContentController.popoverPresentationController {
      popoverPresentationController.permittedArrowDirections = .up
      popoverPresentationController.delegate = popoverContentController
      popoverPresentationController.sourceView = volumeButton
      (AppDelegate.mainWindowHostVC as? UIViewController)?.present(
        popoverContentController,
        animated: true,
        completion: nil
      )
    }
  }
}

// MARK: MusicPlayable

extension MiniPlayerView: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {
    refreshPlayer()
  }

  func didPause() {
    refreshPlayer()
  }

  func didStopPlaying() {
    refreshPlayer()
  }

  func didElapsedTimeChange() {
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
  }

  func didPlaylistChange() {
    refreshPlayer()
  }

  func didArtworkChange() {
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
  }

  func didNowPlayingInfoChange() {
    playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: subtitleLabel,
      albumLabel: nil,
      albumButton: nil,
      albumContainerView: nil
    )
  }

  func didShuffleChange() {
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  func didRepeatChange() {
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }

  func didPlaybackRateChange() {}
}
