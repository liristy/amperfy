//
//  LargeCurrentlyPlayingPlayerView.swift
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
import MediaPlayer
import UIKit

import SwiftUI

// MARK: - LargeDisplayElement

enum LargeDisplayElement {
  case artwork
  case lyrics
  case visualizer
}

// MARK: - AudioAnalyzerView

struct AudioAnalyzerView: View {
  @EnvironmentObject
  var audioAnalyzer: AudioAnalyzer
  let visualizerType: VisualizerType

  var body: some View {
    Group {
      switch visualizerType {
      case .waveform:
        WaveformView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .spectrumBars:
        SpectrumBarsView(
          magnitudes: audioAnalyzer.magnitudes,
          barCount: 32
        )
      case .generativeArt:
        GenerativeArtView(
          magnitudes: audioAnalyzer.magnitudes,
          rms: audioAnalyzer.rms
        )
      case .ring:
        AmplitudeSpectrumView(
          shapeType: .ring,
          magnitudes: audioAnalyzer.magnitudes,
          range: 0 ..< 75,
          rms: audioAnalyzer.rms
        )
      }
    }
    .padding()
  }
}

// MARK: - AudioAnalyzerWrapperView

struct AudioAnalyzerWrapperView: View {
  let visualizerType: VisualizerType

  var body: some View {
    VStack {
      AudioAnalyzerView(visualizerType: visualizerType)
        .environmentObject(appDelegate.player.audioAnalyzer)
    }
  }
}

// MARK: - SwiftUIContentView

class SwiftUIContentView: UIView {
  var hostingController: UIHostingController<AudioAnalyzerWrapperView>?

  public func setupSwiftUIView(
    parentVC: UIViewController,
    parentView: UIView,
    visualizerType: VisualizerType
  ) {
    let swiftUIView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
    let hostingController = UIHostingController(rootView: swiftUIView)
    self.hostingController = hostingController

    parentVC.addChild(hostingController)
    parentView.addSubview(hostingController.view)

    hostingController.view.frame = parentView.frame
    hostingController.view.backgroundColor = .clear

    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.didMove(toParent: parentVC)
  }

  public func updateVisualizerType(_ visualizerType: VisualizerType) {
    hostingController?.rootView = AudioAnalyzerWrapperView(visualizerType: visualizerType)
  }
}

// MARK: - LargeCurrentlyPlayingPlayerView

class LargeCurrentlyPlayingPlayerView: UIView {
  static let rowHeight: CGFloat = 94.0
  static private let margin = UIEdgeInsets(
    top: 0,
    left: UIView.defaultMarginX,
    bottom: 20,
    right: UIView.defaultMarginX
  )

  private var rootView: PopupPlayerVC?
  private var lyricsView: LyricsView?
  private var visualizerHostingView: SwiftUIContentView?
  private var displayElement: LargeDisplayElement = .artwork
  private let artworkShadowView = UIView()
  private let lyricsHeader = UIView()
  private let lyricsArtwork = LibraryEntityImage(frame: .zero)
  private let lyricsTitle = UILabel()
  private let lyricsArtist = UILabel()
  private let lyricsOptions = UIButton(type: .system)
  private let compactFavorite = UIButton(type: .system)
  private var displayAnimator: UIViewPropertyAnimator?
  private var artworkIsPlaying: Bool?
  var isDisplayingLyrics: Bool { displayElement == .lyrics }
  var transitionArtwork: UIImageView { lyricsHeader.isHidden ? artworkImage : lyricsArtwork }
  var transitionArtworkShadow: UIView? { lyricsHeader.isHidden ? artworkShadowView : nil }
  var compactHeader: UIView { lyricsHeader }
  var compactHeaderElements: [UIView] { [lyricsArtwork, lyricsTitle, lyricsArtist] }

  func updateCompactHeaderVisibility() {
    lyricsHeader.isHidden = appDelegate.storage.settings.user.playerDisplayStyle != .compact && !isDisplayingLyrics
  }

  @IBOutlet
  weak var upperContainerView: UIView!
  @IBOutlet
  weak var artworkImage: LibraryEntityImage!
  @IBOutlet
  weak var detailsContainer: UIView!
  @IBOutlet
  weak var titleLabel: MarqueeLabel!
  @IBOutlet
  weak var albumLabel: MarqueeLabel!
  @IBOutlet
  weak var albumButton: UIButton!
  @IBOutlet
  weak var albumContainerView: UIView!
  @IBOutlet
  weak var artistLabel: MarqueeLabel!
  @IBOutlet
  weak var favoriteButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Force a layout to prevent wrong size on first appearance on macOS
    upperContainerView.layoutIfNeeded()
    // Use untransformed geometry; a paused artwork must not shrink its shadow twice.
    artworkShadowView.bounds = artworkImage.bounds
    artworkShadowView.center = artworkImage.center
    artworkShadowView.layer.shadowPath = UIBezierPath(
      roundedRect: artworkShadowView.bounds,
      cornerRadius: 12
    ).cgPath

    let headerHeight = CurrentlyPlayingTableCell.rowHeight
    let artworkSide = CurrentlyPlayingTableCell.artworkSide
    let textX = artworkSide + 14
    lyricsArtwork.frame = CGRect(x: 0, y: (headerHeight - artworkSide) / 2, width: artworkSide, height: artworkSide)
    lyricsTitle.frame = CGRect(x: textX, y: 23, width: max(0, lyricsHeader.bounds.width - textX - 88), height: 24)
    lyricsArtist.frame = CGRect(x: textX, y: 48, width: max(0, lyricsHeader.bounds.width - textX - 88), height: 22)
    compactFavorite.frame = CGRect(x: lyricsHeader.bounds.width - 80, y: 27, width: 40, height: 40)
    lyricsOptions.frame = CGRect(x: lyricsHeader.bounds.width - 40, y: 27, width: 40, height: 40)
    lyricsView?.frame = CGRect(x: 0, y: headerHeight + 8, width: bounds.width, height: max(0, bounds.height - headerHeight - 8))
    visualizerHostingView?.hostingController?.view.frame = upperContainerView.bounds
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    titleLabel.applyAmperfyStyle()
    albumLabel.applyAmperfyStyle()
    artistLabel.applyAmperfyStyle()
    titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
    titleLabel.adjustsFontSizeToFitWidth = false
    artistLabel.font = .systemFont(ofSize: 18, weight: .regular)
    albumLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textColor = .white
    artistLabel.textColor = .white.withAlphaComponent(0.72)
    albumLabel.textColor = .white.withAlphaComponent(0.65)
    artworkImage.contentMode = .scaleAspectFit
    artworkImage.layer.cornerRadius = 12
    artworkImage.layer.cornerCurve = .continuous
    artworkImage.clipsToBounds = true
    artworkShadowView.isUserInteractionEnabled = false
    artworkShadowView.layer.shadowColor = UIColor.black.cgColor
    artworkShadowView.layer.shadowOpacity = 0.3
    artworkShadowView.layer.shadowRadius = 22
    artworkShadowView.layer.shadowOffset = CGSize(width: 0, height: 14)
    upperContainerView.insertSubview(artworkShadowView, belowSubview: artworkImage)
    favoriteButton.accessibilityLabel = "Favorite".localized
    optionsButton.accessibilityLabel = "Song options".localized

    lyricsView = LyricsView()
    rootView?.registerLyricsScrollView(lyricsView!)
    lyricsView!.frame = upperContainerView.bounds
    lyricsView!.onLyricSelected = { [weak self] lyric in
      self?.appDelegate.player.seek(toSecond: lyric.startTime.seconds)
    }
    lyricsView!.onUpwardDrag = { [weak self] in
      self?.rootView?.setLyricsControlsHidden(true)
    }
    addSubview(lyricsView!)
    lyricsArtwork.contentMode = .scaleAspectFit
    lyricsArtwork.layer.cornerRadius = 8
    lyricsArtwork.clipsToBounds = true
    lyricsArtwork.isUserInteractionEnabled = true
    lyricsArtwork.isAccessibilityElement = true
    lyricsArtwork.accessibilityLabel = "Hide Lyrics".localized
    lyricsArtwork.accessibilityTraits = .button
    lyricsArtwork.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(lyricsArtworkPressed)))
    lyricsTitle.font = .systemFont(ofSize: 17, weight: .semibold)
    lyricsTitle.textColor = .white
    lyricsArtist.font = .systemFont(ofSize: 16)
    lyricsArtist.textColor = .white.withAlphaComponent(0.65)
    lyricsOptions.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    lyricsOptions.tintColor = .white
    lyricsOptions.backgroundColor = .clear
    lyricsOptions.accessibilityLabel = "Song options".localized
    compactFavorite.accessibilityLabel = "Favorite".localized
    compactFavorite.addTarget(self, action: #selector(compactFavoritePressed), for: .touchUpInside)
    [lyricsArtwork, lyricsTitle, lyricsArtist, compactFavorite, lyricsOptions].forEach { lyricsHeader.addSubview($0) }
    // One persistent header lives outside both switching/scrolling content views.
    // Its parent, constraints, typography and image stay identical in queue and lyrics.
    if let rootView {
      lyricsHeader.translatesAutoresizingMaskIntoConstraints = false
      rootView.view.addSubview(lyricsHeader)
      NSLayoutConstraint.activate([
        lyricsHeader.leadingAnchor.constraint(equalTo: rootView.largePlayerPlaceholderView.leadingAnchor, constant: 8),
        lyricsHeader.trailingAnchor.constraint(equalTo: rootView.largePlayerPlaceholderView.trailingAnchor, constant: -8),
        lyricsHeader.topAnchor.constraint(equalTo: rootView.largePlayerPlaceholderView.topAnchor),
        lyricsHeader.heightAnchor.constraint(equalToConstant: CurrentlyPlayingTableCell.rowHeight),
      ])
    }
    updateCompactHeaderVisibility()

    visualizerHostingView = SwiftUIContentView()
    visualizerHostingView!.hostingController?.view.frame = upperContainerView.bounds
    if let toWorkOnRootView {
      visualizerHostingView!.setupSwiftUIView(
        parentVC: toWorkOnRootView,
        parentView: self,
        visualizerType: appDelegate.storage.settings.user.selectedVisualizerType
      )
    }

    addSwipeGesturesToArtwork()

    displayElement = getDisplayElementBasedOnConfig()
    refresh()
  }

  private func addSwipeGesturesToArtwork() {
    func createLeftSwipe() -> UISwipeGestureRecognizer {
      let swipeLeft = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeLeft.direction = .left
      return swipeLeft
    }

    func createRightSwipe() -> UISwipeGestureRecognizer {
      let swipeRight = UISwipeGestureRecognizer(
        target: self,
        action: #selector(handleSwipe(_:))
      )
      swipeRight.direction = .right
      return swipeRight
    }

    artworkImage.isUserInteractionEnabled = true
    artworkImage.addGestureRecognizer(createLeftSwipe())
    artworkImage.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.isUserInteractionEnabled = true
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createRightSwipe())
    visualizerHostingView?.hostingController?.view.addGestureRecognizer(createLeftSwipe())
  }

  @objc
  private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
    switch gesture.direction {
    case .left:
      rootView?.controlView?.nextButtonPushed(self)
    case .right:
      rootView?.controlView?.previousButtonPushed(self)
    default:
      break
    }
  }

  func refreshLyricsTime(time: CMTime) {
    lyricsView?.scroll(toTime: time)
  }

  func initializeLyrics() {
    guard isLyricsViewAllowedToDisplay else {
      hideLyrics()
      return
    }

    guard let playable = rootView?.player.currentlyPlaying,
          let song = playable.asSong,
          let account = song.account,
          let lyricsRelFilePath = song.lyricsRelFilePath
    else {
      showLyricsAreNotAvailable()
      return
    }

    Task { @MainActor in do {
      let lyricsList = try await appDelegate.getMeta(account.info).librarySyncer
        .parseLyrics(relFilePath: lyricsRelFilePath)
      guard self.isLyricsViewAllowedToDisplay else {
        self.hideLyrics()
        return
      }

      guard song == self.appDelegate.player.currentlyPlaying?.asSong else { return }
      if let structuredLyrics = lyricsList.getFirstSyncedLyricsOrUnsyncedAsDefault() {
        self.showLyrics(structuredLyrics: structuredLyrics)
      } else {
        self.showLyricsAreNotAvailable()
      }
    } catch {
      guard song == self.appDelegate.player.currentlyPlaying?.asSong else { return }
      guard self.isLyricsViewAllowedToDisplay else {
        self.hideLyrics()
        return
      }
      self.showLyricsAreNotAvailable()
    }}
  }

  var isLyricsViewAllowedToDisplay: Bool {
    displayElement == .lyrics &&
      appDelegate.player.playerMode == .music &&
      appDelegate.storage.settings.accounts.availableApiTypes.contains(.subsonic)
  }

  var isLyricsButtonAllowedToDisplay: Bool {
    appDelegate.player.playerMode == .music &&
      appDelegate.storage.settings.accounts.availableApiTypes.contains(.subsonic)
  }

  public func getDisplayElementBasedOnConfig() -> LargeDisplayElement {
    if appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
      return .lyrics
    } else if appDelegate.storage.settings.user.isPlayerVisualizerDisplayed {
      return .visualizer
    } else {
      return .artwork
    }
  }

  func finishDisplayAnimation() {
    if let displayAnimator, displayAnimator.state == .active {
      displayAnimator.stopAnimation(false)
      displayAnimator.finishAnimation(at: .end)
    }
    displayAnimator = nil
  }

  public func display(element: LargeDisplayElement, animated: Bool = true) {
    finishDisplayAnimation()
    let changed = element != displayElement
    let animate = changed && animated && window != nil && !UIAccessibility.isReduceMotionEnabled
    layoutIfNeeded()
    let sourceArtwork = displayElement == .lyrics ? lyricsArtwork : artworkImage!
    let sourceFrame = sourceArtwork.convert(sourceArtwork.bounds, to: self)
    let transitionImage = sourceArtwork.image
    sourceArtwork.alpha = animate ? 0 : sourceArtwork.alpha
    let previousContent = animate ? snapshotView(afterScreenUpdates: true) : nil
    sourceArtwork.alpha = 1
    displayElement = element
    artworkShadowView.isHidden = element != .artwork
    // Hide the original stack as a whole; hiding its fixed-height arranged views
    // independently would introduce conflicting UIStackView height constraints.
    upperContainerView.superview?.isHidden = element == .lyrics
    updateCompactHeaderVisibility()
    setNeedsLayout()

    switch element {
    case .artwork:
      hideVisualizer()
      hideLyrics()
      showArtwork()
    case .lyrics:
      hideVisualizer()
      almostHideArtwork()
      initializeLyrics()
    case .visualizer:
      hideLyrics()
      almostHideArtwork()
      showVisualizer()
    }
    rootView?.controlView?.refreshLyricsButton()
    if changed { rootView?.lyricsModeDidChange() }
    guard animate, let previousContent else { return }
    layoutIfNeeded()
    let targetArtwork = element == .lyrics ? lyricsArtwork : artworkImage!
    let movingArtwork = UIImageView(image: transitionImage)
    movingArtwork.contentMode = .scaleAspectFit
    movingArtwork.clipsToBounds = true
    movingArtwork.layer.cornerRadius = 10
    movingArtwork.frame = sourceFrame
    previousContent.frame = bounds
    addSubview(previousContent)
    addSubview(movingArtwork)
    targetArtwork.alpha = 0
    let targetFrame = targetArtwork.convert(targetArtwork.bounds, to: self)
    let animator = UIViewPropertyAnimator(duration: 0.55, dampingRatio: 0.88) {
      previousContent.alpha = 0
      movingArtwork.frame = targetFrame
    }
    animator.addCompletion { _ in
      targetArtwork.alpha = 1
      previousContent.removeFromSuperview()
      movingArtwork.removeFromSuperview()
    }
    displayAnimator = animator
    animator.startAnimation()
  }

  public func almostHideArtwork() {
    artworkImage.alpha = 0.1
  }

  public func showArtwork() {
    artworkImage.alpha = 1
  }

  public func hideVisualizer() {
    visualizerHostingView?.hostingController?.view.isHidden = true
    appDelegate.player.audioAnalyzer.isActive = false
  }

  public func showVisualizer() {
    visualizerHostingView?.updateVisualizerType(
      appDelegate.storage.settings.user.selectedVisualizerType
    )
    visualizerHostingView?.hostingController?.view.isHidden = false
    appDelegate.player.audioAnalyzer
      .isActive = (appDelegate.storage.settings.user.playerDisplayStyle == .large)
  }

  private func hideLyrics() {
    lyricsView?.clear()
    lyricsView?.isHidden = true
  }

  private func showLyricsAreNotAvailable() {
    var notAvailableLyrics = StructuredLyrics()
    notAvailableLyrics.synced = false
    var line = LyricsLine()
    line.value = "No Lyrics".localized
    notAvailableLyrics.line.append(line)
    showLyrics(structuredLyrics: notAvailableLyrics)
    lyricsView?.highlightAllLyrics()
  }

  private func showLyrics(structuredLyrics: StructuredLyrics) {
    lyricsView?.display(
      lyrics: structuredLyrics,
      scrollAnimation: appDelegate.storage.settings.user.isLyricsSmoothScrolling
    )
    lyricsView?.isHidden = false
    lyricsView?.scroll(toTime: CMTime(seconds: appDelegate.player.elapsedTime, preferredTimescale: 1000))
  }

  func refresh() {
    rootView?.playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: artistLabel,
      albumLabel: albumLabel,
      albumButton: albumButton,
      albumContainerView: albumContainerView
    )
    lyricsTitle.text = titleLabel.text
    lyricsArtist.text = artistLabel.text
    rootView?.playerHandler?.refreshArtwork(artworkImage: lyricsArtwork)
    rootView?.refreshOptionButton(button: lyricsOptions, rootView: rootView)
    rootView?.refreshFavoriteButton(button: compactFavorite)
    rootView?.refreshFavoriteButton(button: favoriteButton)
    rootView?.refreshOptionButton(button: optionsButton, rootView: rootView)
    display(element: displayElement, animated: false)
    refreshPlaybackAppearance(animated: window != nil)
  }

  func refreshPlaybackAppearance(animated: Bool) {
    let playing = appDelegate.player.isPlaying
    guard artworkIsPlaying != playing else { return }
    artworkIsPlaying = playing
    let scale: CGFloat = playing ? 1 : 0.82
    let changes = {
      self.artworkImage.transform = CGAffineTransform(scaleX: scale, y: scale)
      self.artworkShadowView.transform = CGAffineTransform(scaleX: scale, y: scale)
      self.artworkShadowView.layer.shadowOpacity = playing ? 0.3 : 0.16
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.76,
                     initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                     animations: changes)
    } else {
      UIView.performWithoutAnimation(changes)
    }
  }

  func refreshArtwork() {
    rootView?.playerHandler?.refreshArtwork(artworkImage: lyricsArtwork)
    rootView?.playerHandler?.refreshArtwork(artworkImage: artworkImage)
  }

  @IBAction
  func artworkPressed(_ sender: Any) {
    rootView?.controlView?.displayPlaylistPressed()
  }

  @objc
  func lyricsArtworkPressed() {
    if appDelegate.storage.settings.user.playerDisplayStyle == .compact {
      appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
      appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
      rootView?.controlView?.displayPlaylistPressed()
      return
    }
    guard isDisplayingLyrics else { return }
    appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
    appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
    display(element: .artwork)
  }

  @objc private func compactFavoritePressed() {
    rootView?.favoritePressed()
  }

  @IBAction
  func titlePressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func albumPressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func artistNamePressed(_ sender: Any) {
    rootView?.displayArtistDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func favoritePressed(_ sender: Any) {
    rootView?.favoritePressed()
    rootView?.refreshFavoriteButton(button: favoriteButton)
  }
}
