//
//  PopupPlayerVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import CoreMedia
import UIKit

// MARK: - PopupPlayerVC

class PopupPlayerVC: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
  @IBOutlet
  weak var tableView: UITableView!
  @IBOutlet
  weak var largePlayerPlaceholderView: UIView!
  @IBOutlet
  weak var controlPlaceholderView: UIView!
  @IBOutlet
  weak var backgroundImage: UIImageView!
  @IBOutlet
  weak var closeButtonPlaceholderView: UIView!

  @IBOutlet
  weak var controlPlaceholderHeightConstraint: NSLayoutConstraint!
  private let safetyMarginOnBottom = 8.0
  internal static let backgroundPaletteCache: NSCache<NSString, NSArray> = {
    let cache = NSCache<NSString, NSArray>()
    cache.countLimit = 16
    return cache
  }()
  internal var artworkGradientColors = [UIColor]()
  internal let artworkGradientLayer = CAGradientLayer()
  internal var backgroundArtworkKey: String?
  internal var backgroundArtworkTask: Task<Void, Never>?
  private var portraitLayoutConstraints = [NSLayoutConstraint]()
  private var landscapeLayoutConstraints = [NSLayoutConstraint]()
  private var usesLandscapeLayout = false
  private var lyricsControlsTask: Task<Void, Never>?
  private(set) var areLyricsControlsHidden = false
  let surfaceTransition = PlayerSurfaceTransitionDelegate()
  private lazy var dismissPan = UIPanGestureRecognizer(target: self, action: #selector(dragToDismiss(_:)))
  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  lazy var tableViewKeyCommandsController = TableViewKeyCommandsController(
    tableView: tableView,
    overrideFirstLastIndexPath: IndexPath(
      row: 0,
      section: PlayerSectionCategory.currentlyPlaying.rawValue
    )
  )

  var player: PlayerFacade!
  var playerHandler: PlayerUIHandler?
  var controlView: PlayerControlView?
  var largeCurrentlyPlayingView: LargeCurrentlyPlayingPlayerView?
  var accountNotificationHandler: AccountNotificationHandler?

  var contextPrevQueueSectionHeader: ContextQueuePrevSectionHeader?
  var userQueueSectionHeader: UserQueueSectionHeader?
  var contextNextQueueSectionHeader: ContextQueueNextSectionHeader?
  var activeDisplayedSectionHeader = Set<PlayerSectionCategory>()
  lazy var clearEmptySectionFooter = {
    let view = UIView()
    view.backgroundColor = .clear
    view.isHidden = true
    return view
  }()

  override func viewDidLoad() {
    super.viewDidLoad()

    tableView.delegate = self
    tableView.dataSource = self
    tableView.dragDelegate = self
    tableView.dropDelegate = self
    tableView.dragInteractionEnabled = true

    player = appDelegate.player
    player.addNotifier(notifier: self)
    playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)

    // Keep controls legible over every artwork palette, in either app appearance.
    overrideUserInterfaceStyle = .dark
    view.backgroundColor = UIColor(white: 0.12, alpha: 1)
    backgroundImage.layer.insertSublayer(artworkGradientLayer, at: 0)

    controlPlaceholderHeightConstraint.constant = PlayerControlView
      .frameHeight + safetyMarginOnBottom
    if let createdPlayerControlView = ViewCreator<PlayerControlView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: controlPlaceholderView.bounds.size.width,
        height: controlPlaceholderView.bounds.size.height
      )) {
      controlView = createdPlayerControlView
      createdPlayerControlView.autoresizingMask = [.flexibleWidth]
      createdPlayerControlView.frame.size.height = PlayerControlView.frameHeight
      createdPlayerControlView.prepare(toWorkOnRootView: self)
      controlPlaceholderView.addSubview(createdPlayerControlView)
    }
    controlPlaceholderView.clipsToBounds = true
    let restoreControls = UITapGestureRecognizer(target: self, action: #selector(restoreLyricsControls))
    restoreControls.delegate = self
    view.addGestureRecognizer(restoreControls)
    dismissPan.delegate = self
    dismissPan.maximumNumberOfTouches = 1
    view.addGestureRecognizer(dismissPan)
    tableView.panGestureRecognizer.require(toFail: dismissPan)
    if let createdLargeCurrentlyPlayingView = ViewCreator<LargeCurrentlyPlayingPlayerView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: largePlayerPlaceholderView.bounds.size.width,
        height: largePlayerPlaceholderView.bounds.size.height
      )) {
      largeCurrentlyPlayingView = createdLargeCurrentlyPlayingView
      createdLargeCurrentlyPlayingView.prepare(toWorkOnRootView: self)
      largePlayerPlaceholderView.addSubview(createdLargeCurrentlyPlayingView)
    }

    closeButtonPlaceholderView.isHidden = true
    let closePlayer = UIButton(type: .system)
    closePlayer.translatesAutoresizingMaskIntoConstraints = false
    closePlayer.configuration = .player(isSelected: false)
    closePlayer.accessibilityLabel = "Close".localized
    closePlayer.addTarget(self, action: #selector(dismissFullScreenPlayer), for: .touchUpInside)
    let handle = UIView()
    handle.translatesAutoresizingMaskIntoConstraints = false
    handle.isUserInteractionEnabled = false
    handle.backgroundColor = .white.withAlphaComponent(0.45)
    handle.layer.cornerRadius = 2.5
    closePlayer.addSubview(handle)
    view.addSubview(closePlayer)
    NSLayoutConstraint.activate([
      closePlayer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      closePlayer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: -20),
      closePlayer.widthAnchor.constraint(equalToConstant: 64),
      closePlayer.heightAnchor.constraint(equalToConstant: 40),
      handle.centerXAnchor.constraint(equalTo: closePlayer.centerXAnchor),
      handle.centerYAnchor.constraint(equalTo: closePlayer.centerYAnchor),
      handle.widthAnchor.constraint(equalToConstant: 36),
      handle.heightAnchor.constraint(equalToConstant: 5),
    ])
    configureAdaptiveLayout()

    setupTableView()
    fetchSongInfoAndUpdateViews()

    if let sectionView = ViewCreator<ContextQueuePrevSectionHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: view.bounds.size.width,
        height: ContextQueuePrevSectionHeader.frameHeight
      )) {
      contextPrevQueueSectionHeader = sectionView
      contextPrevQueueSectionHeader?.display(name: "Previous".localized)
    }
    if let sectionView = ViewCreator<UserQueueSectionHeader>.createFromNib(withinFixedFrame: CGRect(
      x: 0,
      y: 0,
      width: view.bounds.size.width,
      height: UserQueueSectionHeader.frameHeight
    )) {
      userQueueSectionHeader = sectionView
      userQueueSectionHeader?.display(name: "Next from Queue".localized, buttonPressAction: clearUserQueue)
    }
    if let sectionView = ViewCreator<ContextQueueNextSectionHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: view.bounds.size.width,
        height: ContextQueueNextSectionHeader.frameHeight
      )) {
      contextNextQueueSectionHeader = sectionView
      contextNextQueueSectionHeader?.prepare(toWorkOnRootView: self)
    }

    accountNotificationHandler = AccountNotificationHandler(
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

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    largeCurrentlyPlayingView?.setNeedsLayout()
    largeCurrentlyPlayingView?.layoutIfNeeded()
    refreshCellMasks()
    applyGradientBackground()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    appDelegate.userStatistics.visited(.popupPlayer)
    becomeFirstResponder()
    changeDisplayStyleVisually(
      to: appDelegate.storage.settings.user.playerDisplayStyle,
      animated: false
    )
    reloadData()
    scrollToCurrentlyPlayingRow()
    controlView?.refreshView()
    refresh()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    lyricsControlsTask?.cancel()
    resignFirstResponder()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    lyricsModeDidChange()
  }

  func lyricsModeDidChange() {
    lyricsControlsTask?.cancel()
    setLyricsControlsHidden(false)
    scheduleLyricsControlsHide()
  }

  private func scheduleLyricsControlsHide() {
    lyricsControlsTask?.cancel()
    guard largeCurrentlyPlayingView?.isDisplayingLyrics == true,
          appDelegate.storage.settings.user.playerDisplayStyle == .large,
          viewIfLoaded?.window != nil else { return }
    lyricsControlsTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      if self.presentedViewController != nil || self.isTrackingControl(in: self.controlPlaceholderView) ||
        UIAccessibility.isVoiceOverRunning {
        self.scheduleLyricsControlsHide()
      } else {
        self.setLyricsControlsHidden(true)
      }
    }
  }

  private func isTrackingControl(in view: UIView) -> Bool {
    (view as? UIControl)?.isTracking == true || view.subviews.contains { isTrackingControl(in: $0) }
  }

  func setLyricsControlsHidden(_ hidden: Bool, animated: Bool = true) {
    guard !hidden || (largeCurrentlyPlayingView?.isDisplayingLyrics == true &&
      appDelegate.storage.settings.user.playerDisplayStyle == .large) else { return }
    guard hidden != areLyricsControlsHidden else { return }
    areLyricsControlsHidden = hidden
    view.layoutIfNeeded()
    controlPlaceholderView.isUserInteractionEnabled = !hidden
    controlPlaceholderView.accessibilityElementsHidden = hidden
    controlPlaceholderHeightConstraint.constant = hidden && !usesLandscapeLayout ? 0 :
      PlayerControlView.frameHeight + safetyMarginOnBottom
    let changes = {
      self.controlPlaceholderView.alpha = hidden ? 0 : 1
      self.view.layoutIfNeeded()
    }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.4, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut],
                     animations: changes)
    } else { changes() }
  }

  @objc func restoreLyricsControls() {
    setLyricsControlsHidden(false)
    scheduleLyricsControlsHide()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    let isDismissPan = gestureRecognizer === dismissPan
    guard isDismissPan || areLyricsControlsHidden else { return false }
    var touchedView = touch.view
    while let current = touchedView {
      if isDismissPan ? (current is UISlider) : (current is UIControl) { return false }
      if !isDismissPan, current === largeCurrentlyPlayingView?.transitionArtwork { return false }
      touchedView = current.superview
    }
    return true
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dismissPan else { return true }
    let velocity = dismissPan.velocity(in: view)
    guard velocity.y > 0, velocity.y > abs(velocity.x), transitionCoordinator == nil,
          presentedViewController == nil else { return false }
    var touchedView = view.hitTest(dismissPan.location(in: view), with: nil)
    while let current = touchedView {
      // Keep downward scrolling available when reading earlier lyrics or queue items.
      if let scrollView = current as? UIScrollView,
         scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1 { return false }
      touchedView = current.superview
    }
    return true
  }

  func registerLyricsScrollView(_ lyricsView: LyricsView) {
    lyricsView.panGestureRecognizer.require(toFail: dismissPan)
  }

  func configurePresentation(sourcePlayer: UIView?) {
    surfaceTransition.sourcePlayer = sourcePlayer
    modalPresentationStyle = .fullScreen
    transitioningDelegate = surfaceTransition
  }

  var transitionArtwork: UIImageView? {
    return largeCurrentlyPlayingView?.transitionArtwork
  }

  @objc private func dragToDismiss(_ pan: UIPanGestureRecognizer) {
    switch pan.state {
    case .began: beginInteractiveDismissal()
    case .changed: updateInteractiveDismissal(translation: pan.translation(in: view.window).y)
    case .ended:
      endInteractiveDismissal(translation: pan.translation(in: view.window).y,
                              velocity: pan.velocity(in: view.window).y)
    case .cancelled, .failed: endInteractiveDismissal(translation: 0, velocity: 0, cancelled: true)
    default: break
    }
  }

  func beginInteractiveDismissal() {
    guard surfaceTransition.interaction == nil, !isBeingDismissed else { return }
    lyricsControlsTask?.cancel()
    let interaction = UIPercentDrivenInteractiveTransition()
    interaction.timingCurve = UISpringTimingParameters(dampingRatio: UIAccessibility.isReduceMotionEnabled ? 1 : 0.74)
    surfaceTransition.interaction = interaction
    dismiss(animated: true) { [weak self] in self?.surfaceTransition.interaction = nil }
  }

  func updateInteractiveDismissal(translation: CGFloat) {
    surfaceTransition.interaction?.update(min(0.99, max(0, translation / max(view.bounds.height, 1))))
  }

  func endInteractiveDismissal(translation: CGFloat, velocity: CGFloat, cancelled: Bool = false) {
    guard let interaction = surfaceTransition.interaction else { return }
    let shouldFinish = !cancelled && velocity > -100 &&
      (translation > 90 || (translation > 12 && velocity > 650))
    if shouldFinish { interaction.finish() } else { interaction.cancel() }
    surfaceTransition.interaction = nil
    if !shouldFinish { scheduleLyricsControlsHide() }
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    adjustLayoutMargins()
    let landscape = view.bounds.width > 600 && view.bounds.height < 500
    if landscape != usesLandscapeLayout {
      NSLayoutConstraint.deactivate(
        landscape ? portraitLayoutConstraints : landscapeLayoutConstraints
      )
      NSLayoutConstraint.activate(
        landscape ? landscapeLayoutConstraints : portraitLayoutConstraints
      )
      usesLandscapeLayout = landscape
      controlPlaceholderHeightConstraint.constant = areLyricsControlsHidden && !landscape ? 0 :
        PlayerControlView.frameHeight + safetyMarginOnBottom
    }
  }

  private func configureAdaptiveLayout() {
    // The queue begins below the same fixed header used by lyrics.
    for constraint in view.constraints where
      (constraint.firstItem as? UIView) === tableView && constraint.firstAttribute == .top {
      constraint.isActive = false
    }
    tableView.topAnchor.constraint(equalTo: largePlayerPlaceholderView.topAnchor,
                                   constant: CurrentlyPlayingTableCell.rowHeight + 8).isActive = true
    let contentViews: [UIView] = [largePlayerPlaceholderView, tableView, controlPlaceholderView]
    portraitLayoutConstraints = view.constraints.filter { constraint in
      (constraint.firstItem as? UIView) !== largeCurrentlyPlayingView?.compactHeader &&
      contentViews.contains { content in
        (constraint.firstItem as? UIView) === content ||
          (constraint.secondItem as? UIView) === content
      }
    }
    landscapeLayoutConstraints = [
      largePlayerPlaceholderView.leadingAnchor.constraint(
        equalTo: view.layoutMarginsGuide.leadingAnchor
      ),
      largePlayerPlaceholderView.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: 16
      ),
      largePlayerPlaceholderView.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor,
        constant: -8
      ),
      largePlayerPlaceholderView.trailingAnchor.constraint(
        equalTo: controlPlaceholderView.leadingAnchor,
        constant: -32
      ),
      largePlayerPlaceholderView.widthAnchor.constraint(
        equalTo: controlPlaceholderView.widthAnchor
      ),
      controlPlaceholderView.trailingAnchor.constraint(
        equalTo: view.layoutMarginsGuide.trailingAnchor
      ),
      controlPlaceholderView.centerYAnchor.constraint(
        equalTo: largePlayerPlaceholderView.centerYAnchor
      ),
      tableView.leadingAnchor.constraint(equalTo: largePlayerPlaceholderView.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: largePlayerPlaceholderView.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: largePlayerPlaceholderView.topAnchor,
                                     constant: CurrentlyPlayingTableCell.rowHeight + 8),
      tableView.bottomAnchor.constraint(equalTo: largePlayerPlaceholderView.bottomAnchor),
    ]
  }

  func fetchSongInfoAndUpdateViews() {
    guard appDelegate.storage.settings.user.isOnlineMode,
          let song = player.currentlyPlaying?.asSong,
          let account = song.account
    else { return }

    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer.sync(song: song)
      self.refreshCurrentlyPlayingInfoView()
    } catch {
      self.appDelegate.eventLogger.report(topic: "Song Info".localized, error: error)
    }}
  }

  func reloadData() {
    tableView.reloadData()
    scrollToCurrentlyPlayingRow()
  }

  func scrollToCurrentlyPlayingRow() {
    tableView.scrollToRow(
      at: IndexPath(row: 0, section: PlayerSectionCategory.currentlyPlaying.rawValue),
      at: .top,
      animated: false
    )
  }

  func favoritePressed() {
    switch player.playerMode {
    case .music:
      guard let playableInfo = player.currentlyPlaying else { return }
      if playableInfo.isSong, let account = playableInfo.account {
        Task { @MainActor in
          do {
            try await playableInfo
              .remoteToggleFavorite(
                syncer: self.appDelegate.getMeta(account.info)
                  .librarySyncer
              )
          } catch {
            self.appDelegate.eventLogger.report(topic: "Toggle Favorite".localized, error: error)
          }
          self.refresh()
        }
      } else if let radio = playableInfo.asRadio,
                let siteURL = radio.siteURL {
        UIApplication.shared.open(siteURL)
      }
    case .podcast:
      guard let podcastEpisode = player.currentlyPlaying?.asPodcastEpisode
      else { return }
      let plainDetailsVC = PlainDetailsVC()
      plainDetailsVC.display(podcastEpisode: podcastEpisode, on: self)
      present(plainDetailsVC, animated: true)
    }
  }

  func displayArtistDetail() {
    if let song = player.currentlyPlaying?.asSong, let artist = song.artist,
       let account = artist.account {
      let artistDetailVC = AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist)
      closePopupPlayerAndDisplayInLibraryTab(vc: artistDetailVC)
    }
  }

  func displayAlbumDetail() {
    if let song = player.currentlyPlaying?.asSong, let album = song.album,
       let account = album.account {
      let albumDetailVC = AppStoryboard.Main.segueToAlbumDetail(
        account: account,
        album: album,
        songToScrollTo: song
      )
      closePopupPlayerAndDisplayInLibraryTab(vc: albumDetailVC)
    }
  }

  func displayPodcastDetail() {
    if let podcastEpisode = player.currentlyPlaying?.asPodcastEpisode,
       let podcast = podcastEpisode.podcast,
       let account = podcastEpisode.account {
      let podcastDetailVC = AppStoryboard.Main.segueToPodcastDetail(
        account: account,
        podcast: podcast,
        episodeToScrollTo: podcastEpisode
      )
      closePopupPlayerAndDisplayInLibraryTab(vc: podcastDetailVC)
    }
  }

  func closePopupPlayer() {
    dismiss(animated: true)
  }

  @objc private func dismissFullScreenPlayer() { closePopupPlayer() }

  func closePopupPlayerAndDisplayInLibraryTab(vc: UIViewController) {
    guard let hostingSplitVC = AppDelegate.mainWindowHostVC else { return }
    hostingSplitVC.visualizePopupPlayer(direction: .close, animated: true, completion: { () in
      hostingSplitVC.pushNavLibrary(vc: vc)
    })
  }

  func refreshUserQueueSectionHeader() {
    guard let userQueueSectionView = userQueueSectionHeader else { return }
    if player.userQueueCount == 0 {
      userQueueSectionView.hide()
    } else {
      userQueueSectionView.display(
        name: PlayerQueueType.user.description,
        buttonPressAction: clearUserQueue
      )
    }
  }

  func refreshContextQueueSectionHeader() {
    guard let contextNextQueueSectionHeader = contextNextQueueSectionHeader else { return }
    contextNextQueueSectionHeader.refresh()
  }

  // MARK: - UIScrollViewDelegate

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    refreshCellMasks()
  }

  func refreshCellMasks() {
    guard let topSection = Array(activeDisplayedSectionHeader)
      .sorted(by: { $0.rawValue < $1.rawValue }).first
    else { return }

    let topSectionHeight = tableView(tableView, heightForHeaderInSection: topSection.rawValue)
    let scrollOffset = tableView.contentOffset.y

    for cell in tableView.visibleCells {
      let hiddenFrameHeight = scrollOffset + topSectionHeight - cell.frame.origin.y
      if hiddenFrameHeight >= 0 || hiddenFrameHeight <= cell.frame.size.height {
        if let customCell = cell as? PlayableTableCell {
          customCell.maskCell(fromTop: hiddenFrameHeight)
        }
      }
    }
  }

  func refreshCellsContent() {
    for cell in tableView.visibleCells {
      guard let playableCell = cell as? PlayableTableCell else { continue }
      playableCell.refresh()
    }
  }
}

// MARK: MusicPlayable

extension PopupPlayerVC: MusicPlayable {
  func didStartPlayingFromBeginning() {
    fetchSongInfoAndUpdateViews()
    largeCurrentlyPlayingView?.initializeLyrics()
  }

  func didStartPlaying() {
    reloadData()
    refresh()
    largeCurrentlyPlayingView?.refreshPlaybackAppearance(animated: true)
  }

  func didStopPlaying() {
    reloadData()
    refresh()
  }

  func didPlaylistChange() {
    reloadData()
    refresh()
  }

  func didPause() {
    largeCurrentlyPlayingView?.refreshPlaybackAppearance(animated: true)
  }
  func didElapsedTimeChange() {}

  func didLyricsTimeChange(time: CMTime) {
    largeCurrentlyPlayingView?.refreshLyricsTime(time: time)
  }

  func didArtworkChange() {
    refreshCurrentlyPlayingArtworks()
  }

  func didNowPlayingInfoChange() {
    refreshCurrentlyPlayingInfoView()
  }

  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}
