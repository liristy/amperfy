//
//  SceneDelegate.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 17.08.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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
import OSLog
import UIKit

// MARK: - MainSceneHostingViewController

@MainActor
protocol MainSceneHostingViewController {
  func pushNavLibrary(vc: UIViewController)
  func pushLibraryCategory(vc: UIViewController)
  func pushTabCategory(tabCategory: TabNavigatorItem)
  func displaySearch()

  func visualizePopupPlayer(
    direction: PopupPlayerDirection,
    animated: Bool,
    completion completionBlock: (() -> ())?
  )

  func getSafeAreaExtension() -> CGFloat
  var miniPlayer: MiniPlayerView? { get }
}

extension MainSceneHostingViewController {
  func visualizePopupPlayer(
    direction: PopupPlayerDirection,
    animated: Bool,
    completion completionBlock: (() -> ())? = nil
  ) {
    guard let topView = AppDelegate.topViewController(),
          let hostVC = AppDelegate.mainWindowHostVC
    else { return }

    if let presentedViewController = topView.presentedViewController {
      presentedViewController.dismiss(animated: animated) {
        if direction == .open {
          hostVC.miniPlayer?.openPlayerView(completion: completionBlock)
        } else {
          completionBlock?()
        }
      }
    } else {
      if direction == .open || direction == .toggle {
        hostVC.miniPlayer?.openPlayerView(completion: completionBlock)
      } else {
        completionBlock?()
      }
    }
  }
}

// MARK: - SceneDelegate

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  #if false // set to true to adjust Main window to App Connect compatible screen size for screenshots
    static let mainWindowSize = CGSizeMake(1168, 688) // 2560 x 1600
  #endif

  public lazy var log = {
    AmperKit.shared.log
  }()

  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    os_log("willConnectTo", log: self.log, type: .info)
    /** Process the quick action if the user selected one to launch the app.
         Grab a reference to the shortcutItem to use in the scene.
     */
    if let shortcutItem = connectionOptions.shortcutItem {
      // Save it off for later when we become active.
      appDelegate.quickActionsManager.savedShortCutItemForLaterUse(savedShortCutItem: shortcutItem)
    }
    // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
    // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
    // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
    guard let windowScene = scene as? UIWindowScene else { return }
    window = UIWindow(windowScene: windowScene)
    appDelegate.window = window
    var initialViewController: UIViewController?

    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-launch-screen") {
        window?.rootViewController = UIStoryboard(name: "LaunchScreen", bundle: nil).instantiateInitialViewController()
        window?.makeKeyAndVisible()
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(1))
          guard let window = self.window else { return }
          let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
          }
          try? image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("launch-screen.png"))
        }
        return
      }
    #endif

    #if false
      windowScene.sizeRestrictions?.minimumSize = Self.mainWindowSize
    #endif
    if let activeAccountInfo = AmperKit.shared.storage.settings.accounts.active {
      let account = appDelegate.storage.main.library.getAccount(info: activeAccountInfo)
      if !AmperKit.shared.storage.settings.app.isLibrarySynced {
        initialViewController = AppStoryboard.Main.segueToSync(account: account)
      } else if AmperKit.shared.libraryUpdater.isVisualUpadateNeeded {
        initialViewController = AppStoryboard.Main.segueToUpdate()
      } else {
        initialViewController = AppStoryboard.Main.segueToMainWindow(account: account)
      }
    } else {
      initialViewController = AppStoryboard.Main.segueToLogin()
    }
    replaceMainRootViewController(vc: initialViewController!)

    window?.makeKeyAndVisible()

    appDelegate.setAppAppearanceMode(style: appDelegate.storage.settings.user.appearanceMode)
    AmperfyAppShortcuts.updateAppShortcutParameters()
  }

  func replaceMainRootViewController(vc: UIViewController) {
    window?.rootViewController = vc
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-login"),
         vc is MainSceneHostingViewController {
        Task { @MainActor in
          // Allow view loading, initial home requests and artwork downloads to complete.
          try? await Task.sleep(for: .seconds(10))
          guard let activeAccount = self.appDelegate.storage.settings.accounts.active,
                self.appDelegate.storage.settings.accounts.getSetting(activeAccount).read
                  .initialSyncCompletionStatus == .completed else { return }
          if ProcessInfo.processInfo.arguments.contains("--smoke-player") {
            func smokeLog(_ message: String) {
              FileHandle.standardOutput.write(Data((message + "\n").utf8))
            }
            do {
              // Reproduce UIKit's reload/reuse ordering: a new cell may be bound
              // before the old one is recycled. Its highlight binding must survive.
              var lyricLine = LyricsLine()
              lyricLine.value = "Highlight reuse regression"
              let lyricModel = LyricTableCellModel(lyric: lyricLine)
              let oldLyricCell = LyricTableCell(style: .default, reuseIdentifier: nil)
              let newLyricCell = LyricTableCell(style: .default, reuseIdentifier: nil)
              oldLyricCell.display(model: lyricModel)
              newLyricCell.display(model: lyricModel)
              oldLyricCell.prepareForReuse()
              lyricModel.isActiveLine = true
              guard newLyricCell.accessibilityTraits.contains(.selected) else {
                smokeLog("Recycling the old lyrics cell disconnected the visible highlight")
                return
              }
              smokeLog("Lyrics highlight survived replacement-cell reuse")
              smokeLog("Player smoke: preparing playback")
              let library = self.appDelegate.storage.main.library
              let account = library.getAccount(info: activeAccount)
              guard let album = library.getAlbum(for: account, id: "album-1", isDetailFaultResolution: false) else { return }
              let syncer = self.appDelegate.getMeta(activeAccount).librarySyncer
              try await syncer.sync(album: album)
              guard let song = library.getSong(for: account, id: "song-1") else { return }
              try await syncer.sync(song: song)
              guard song.lyricsRelFilePath != nil else { return }
              guard let nextSong = library.getSong(for: account, id: "song-2") else { return }
              try await syncer.sync(song: nextSong)
              self.appDelegate.storage.settings.user.playerDisplayStyle = .large
              self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
              self.appDelegate.player.isAutoCachePlayedItems = false
              self.appDelegate.player.setRepeatMode(.off)
              self.appDelegate.player.play(context: PlayContext(name: "Gapless smoke", playables: [song, nextSong]))
              try await Task.sleep(for: .seconds(3))
              guard self.appDelegate.player.elapsedTime > 0 else { return }
              vc.dismiss(animated: false)
              guard let miniPlayer = (vc as? MainSceneHostingViewController)?.miniPlayer else { return }
              miniPlayer.beginTrackDrag()
              miniPlayer.updateTrackDrag(translation: -120)
              guard self.appDelegate.player.currentlyPlaying == song,
                    miniPlayer.trackDragTranslation == -120,
                    miniPlayer.trackDragNextSong == nextSong,
                    miniPlayer.trackDragPreviousSong == nil else { return }
              let dragImage = UIGraphicsImageRenderer(bounds: vc.view.bounds).image { _ in
                vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
              }
              try dragImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-mini-drag.png"))
              miniPlayer.updateTrackDrag(translation: -8)
              miniPlayer.endTrackDrag(velocity: 0)
              try await Task.sleep(for: .milliseconds(350))
              guard self.appDelegate.player.currentlyPlaying == song,
                    miniPlayer.trackDragTranslation == 0 else { return }
              miniPlayer.beginTrackDrag()
              miniPlayer.updateTrackDrag(translation: 120)
              guard miniPlayer.trackDragTranslation < 40 else { return }
              miniPlayer.endTrackDrag(velocity: 300)
              try await Task.sleep(for: .milliseconds(350))
              guard self.appDelegate.player.currentlyPlaying == song else { return }
              smokeLog("Mini player intermediate drag, pull-back and cancellation preserved the song")
              miniPlayer.beginTrackDrag()
              miniPlayer.updateTrackDrag(translation: -120)
              miniPlayer.endTrackDrag(velocity: -300)
              try await Task.sleep(for: .seconds(2))
              guard self.appDelegate.player.currentlyPlaying == nextSong else {
                smokeLog("Mini player left swipe did not play the next track")
                return
              }
              self.appDelegate.player.seek(toSecond: 35)
              miniPlayer.beginTrackDrag()
              miniPlayer.updateTrackDrag(translation: 170)
              guard miniPlayer.trackDragPreviousSong == song,
                    miniPlayer.trackDragNextSong == nil,
                    self.appDelegate.player.currentlyPlaying == nextSong else { return }
              let previousImage = UIGraphicsImageRenderer(bounds: vc.view.bounds).image { _ in
                vc.view.drawHierarchy(in: vc.view.bounds, afterScreenUpdates: true)
              }
              try previousImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-mini-drag-previous.png"))
              miniPlayer.endTrackDrag(velocity: 0, cancelled: true)
              try await Task.sleep(for: .milliseconds(350))
              guard self.appDelegate.player.currentlyPlaying == nextSong else { return }
              miniPlayer.beginTrackDrag()
              miniPlayer.updateTrackDrag(translation: 120)
              miniPlayer.endTrackDrag(velocity: 300)
              try await Task.sleep(for: .seconds(2))
              guard self.appDelegate.player.currentlyPlaying == song else {
                smokeLog("Mini player right swipe replayed the current track instead of switching back")
                return
              }
              smokeLog("Mini player swipes switched next and previous tracks")
              // Preview the actual queue order, including user-queued songs and repeat wrapping.
              self.appDelegate.player.insertUserQueue(playables: [song])
              miniPlayer.beginTrackDrag()
              guard miniPlayer.trackDragNextSong == song else { return }
              miniPlayer.endTrackDrag(velocity: 0, cancelled: true)
              try await Task.sleep(for: .milliseconds(250))
              self.appDelegate.player.clearUserQueue()
              self.appDelegate.player.setRepeatMode(.all)
              miniPlayer.beginTrackDrag()
              guard miniPlayer.trackDragPreviousSong == nextSong else { return }
              miniPlayer.endTrackDrag(velocity: 0, cancelled: true)
              try await Task.sleep(for: .milliseconds(250))
              self.appDelegate.player.setRepeatMode(.off)
              smokeLog("Adjacent song previews, edge resistance, user queue priority and repeat wrapping passed")
              if let tabHost = vc as? UITabBarController {
                tabHost.view.layoutIfNeeded()
                guard tabHost.bottomAccessory != nil,
                      tabHost.tabBarMinimizeBehavior == .onScrollDown,
                      miniPlayer.glassContainer.superview !== tabHost.view else {
                  smokeLog("Mini player is not using the system's collapsible tab accessory")
                  return
                }
                miniPlayer.glassContainer.traitOverrides.tabAccessoryEnvironment = .inline
                tabHost.view.layoutIfNeeded()
                guard miniPlayer.traitCollection.tabAccessoryEnvironment == .inline else { return }
                miniPlayer.glassContainer.traitOverrides.remove(UITraitTabAccessoryEnvironment.self)
                tabHost.view.layoutIfNeeded()
                smokeLog("Native mini player accessory and inline environment restored")
                let image = UIGraphicsImageRenderer(bounds: tabHost.view.bounds).image { _ in
                  tabHost.view.drawHierarchy(in: tabHost.view.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-mini-spacing.png"))
              }
              guard PlayerArtworkAnimator(isPresenting: true, sourceArtwork: nil)
                .transitionDuration(using: nil) <= 0.3 else { return }
              miniPlayer.openPlayerView()
              func descendants(of view: UIView) -> [UIView] {
                view.subviews + view.subviews.flatMap { descendants(of: $0) }
              }
              // UIKit may defer presentation until the next run-loop turn. Sample frames
              // throughout the transition instead of assuming one fixed scheduling delay.
              var sampledZoom = false
              var lastSample = "no transition view"
              for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                guard let popup = vc.presentedViewController as? PopupPlayerVC,
                      let window = popup.view.window,
                      let movingCover = descendants(of: window).first(where: {
                        $0.accessibilityIdentifier == "player-transition-artwork"
                      }), let animatedFrame = movingCover.layer.presentation()?.frame,
                      let finalCover = popup.transitionArtwork else { continue }
                lastSample = "width \(animatedFrame.width), destination \(finalCover.bounds.width)"
                guard animatedFrame.width > 60,
                      animatedFrame.width < finalCover.bounds.width - 1 else { continue }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                  window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-opening.png"))
                sampledZoom = true
                break
              }
              guard sampledZoom, let popup = vc.presentedViewController as? PopupPlayerVC else {
                smokeLog("Cover zoom did not interpolate: \(lastSample)")
                return
              }
              smokeLog("Cover zoom interpolated: \(lastSample)")
              try await Task.sleep(for: .seconds(1))
              guard popup.largePlayerPlaceholderView.transform == .identity,
                    popup.transitionArtwork?.isHidden == false else { return }
              popup.beginInteractiveDismissal()
              try await Task.sleep(for: .milliseconds(80))
              popup.updateInteractiveDismissal(translation: 70)
              try await Task.sleep(for: .milliseconds(80))
              popup.endInteractiveDismissal(translation: 70, velocity: -150, cancelled: true)
              try await Task.sleep(for: .seconds(1))
              guard vc.presentedViewController === popup, popup.view.transform == .identity,
                    popup.transitionArtwork?.isHidden == false else {
                smokeLog("Cancelled player dismissal did not restore the player")
                return
              }
              smokeLog("Cancelled dismissal restored the player")
              func screenshot(_ name: String) throws {
                let image = UIGraphicsImageRenderer(bounds: popup.view.bounds).image { _ in
                  popup.view.drawHierarchy(in: popup.view.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name))
              }
              guard let fullPlayer = popup.largeCurrentlyPlayingView,
                    fullPlayer.titleLabel.font.pointSize >= fullPlayer.artistLabel.font.pointSize + 6 else {
                smokeLog("Full player title is not larger than the artist after appearance")
                return
              }
              try screenshot("player-artwork-landscape.png")
              // Leave enough time for the real engine to preload the second stream.
              self.appDelegate.player.seek(toSecond: 174)
              try await Task.sleep(for: .seconds(9))
              guard self.appDelegate.player.currentlyPlaying == nextSong,
                    popup.largeCurrentlyPlayingView?.titleLabel.text == nextSong.title else {
                smokeLog("Gapless smoke: next audio and displayed song disagree")
                return
              }
              smokeLog("Gapless playback updated song and player title")
              try screenshot("player-next-song.png")
              self.appDelegate.player.seek(toSecond: 42)
              try await Task.sleep(for: .seconds(1))
              self.appDelegate.player.pause()
              guard self.appDelegate.player.elapsedTime >= 41 else { return }
              self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed = true
              popup.largeCurrentlyPlayingView?.display(element: .lyrics)
              try await Task.sleep(for: .seconds(1))
              popup.largeCurrentlyPlayingView?.refreshLyricsTime(time: CMTime(seconds: 42, preferredTimescale: 1000))
              guard let lyricsTable = descendants(of: popup.view).compactMap({ $0 as? LyricsView }).first else { return }
              func activeLyricIsVisible() -> Bool {
                lyricsTable.layoutIfNeeded()
                return lyricsTable.visibleCells.contains { $0.accessibilityTraits.contains(.selected) }
              }
              guard activeLyricIsVisible() else { smokeLog("Lyrics did not highlight when opened"); return }
              let heightWithControls = popup.largePlayerPlaceholderView.bounds.height
              try screenshot("player-lyrics-controls.png")
              try await Task.sleep(for: .seconds(5))
              guard popup.areLyricsControlsHidden,
                    popup.largePlayerPlaceholderView.bounds.height > heightWithControls + 200 else {
                smokeLog("Lyrics controls did not hide and expand lyrics")
                return
              }
              popup.largeCurrentlyPlayingView?.refreshLyricsTime(time: CMTime(seconds: 42, preferredTimescale: 1000))
              guard activeLyricIsVisible() else { smokeLog("Immersive lyrics lost their highlight"); return }
              try screenshot("player-lyrics-immersive.png")
              popup.restoreLyricsControls()
              try await Task.sleep(for: .seconds(1))
              guard !popup.areLyricsControlsHidden,
                    abs(popup.largePlayerPlaceholderView.bounds.height - heightWithControls) < 1 else { return }
              guard activeLyricIsVisible() else { smokeLog("Restoring controls lost the lyrics highlight"); return }
              smokeLog("Lyrics stayed highlighted across immersive layout changes")
              try screenshot("player-lyrics-restored.png")
              // Both compact headers must share one artwork size throughout the
              // queue/lyrics transition, including its intermediate frames.
              @MainActor func compactArtworkStayedSmall() async throws -> Bool {
                var sampled = false
                for _ in 0..<22 {
                  try await Task.sleep(for: .milliseconds(16))
                  if let moving = descendants(of: popup.view).first(where: {
                    $0.accessibilityIdentifier == "player-layout-transition-artwork"
                  }) {
                    sampled = true
                    let width = moving.layer.presentation()?.bounds.width ?? moving.bounds.width
                    if abs(width - CurrentlyPlayingTableCell.artworkSide) > 1 { return false }
                  }
                }
                return sampled
              }
              guard abs((popup.transitionArtwork?.bounds.width ?? 0) - CurrentlyPlayingTableCell.artworkSide) < 1 else { return }
              popup.controlView?.displayPlaylistPressed()
              guard try await compactArtworkStayedSmall(),
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .compact,
                    abs((popup.transitionArtwork?.bounds.width ?? 0) - CurrentlyPlayingTableCell.artworkSide) < 1 else {
                smokeLog("Lyrics to queue enlarged the compact artwork")
                return
              }
              try screenshot("player-queue-from-lyrics.png")
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              guard try await compactArtworkStayedSmall(),
                    popup.largeCurrentlyPlayingView?.isDisplayingLyrics == true,
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .large,
                    abs((popup.transitionArtwork?.bounds.width ?? 0) - CurrentlyPlayingTableCell.artworkSide) < 1 else {
                smokeLog("Queue to lyrics enlarged the compact artwork")
                return
              }
              try screenshot("player-lyrics-from-queue.png")
              smokeLog("Lyrics and queue artwork stayed the same size throughout both transitions")
              guard let lyricsView = descendants(of: popup.view).compactMap({ $0 as? LyricsView }).first else { return }
              lyricsView.handleDrag(velocity: CGPoint(x: 0, y: 300))
              guard !popup.areLyricsControlsHidden else { return }
              lyricsView.handleDrag(velocity: CGPoint(x: 0, y: -300))
              try await Task.sleep(for: .milliseconds(500))
              guard popup.areLyricsControlsHidden else { return }
              try screenshot("player-lyrics-upward.png")
              popup.largeCurrentlyPlayingView?.lyricsArtworkPressed()
              try await Task.sleep(for: .seconds(1))
              guard popup.largeCurrentlyPlayingView?.isDisplayingLyrics == false,
                    !self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed,
                    !popup.areLyricsControlsHidden,
                    vc.presentedViewController === popup else {
                smokeLog("Lyrics artwork tap did not return to the cover and restore controls")
                return
              }
              smokeLog("Lyrics artwork tap returned to the full cover")
              self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed = true
              popup.largeCurrentlyPlayingView?.display(element: .lyrics)
              try await Task.sleep(for: .seconds(1))
              // A short, quick downward drag should finish instead of requiring a long swipe.
              popup.beginInteractiveDismissal()
              try await Task.sleep(for: .milliseconds(80))
              popup.updateInteractiveDismissal(translation: 28)
              popup.endInteractiveDismissal(translation: 28, velocity: 900)
              try await Task.sleep(for: .seconds(1))
              // Returning home can present the first-run welcome message. Check the
              // player's own presentation relationship, not whether every modal is gone.
              guard vc.presentedViewController !== popup, popup.presentingViewController == nil else {
                smokeLog("Quick downward drag did not dismiss the player")
                return
              }
              smokeLog("Cover zoom, cancelled dismissal, upward lyrics gesture and quick dismissal passed")
              if let tabHost = vc as? UITabBarController,
                 let libraryTab = tabHost.tabs.first(where: { $0.identifier == "Tabs.Library" }) {
                vc.dismiss(animated: false)
                tabHost.selectedTab = libraryTab
                try await Task.sleep(for: .seconds(1))
                tabHost.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: tabHost.view.bounds).image { _ in
                  tabHost.view.drawHierarchy(in: tabHost.view.bounds, afterScreenUpdates: true)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-library-defaults.png"))
              }
              // Exercise the real Subsonic request without waiting half a long fixture track.
              song.playDuration = 2
              library.saveContext()
              self.appDelegate.player.play(context: PlayContext(name: "Scrobble smoke", playables: [song]))
              try await Task.sleep(for: .seconds(3))
              song.isFavorite = true
              nextSong.isFavorite = false
              library.saveContext()
              _ = try await ShuffleFavoritesIntent().perform()
              try await Task.sleep(for: .seconds(1))
              guard self.appDelegate.player.currentlyPlaying == song,
                    self.appDelegate.player.isShuffle else {
                smokeLog("Favorites shortcut did not shuffle only favorite songs")
                return
              }
              var timerIntent = SetSleepTimerIntent()
              timerIntent.minutes = 3
              _ = try await timerIntent.perform()
              guard let sleepTimer = self.appDelegate.sleepTimer,
                    abs(sleepTimer.fireDate.timeIntervalSinceNow - 180) < 2 else { return }
              timerIntent.minutes = 0
              _ = try await timerIntent.perform()
              guard self.appDelegate.sleepTimer == nil, self.appDelegate.player.isPlaying else { return }
              timerIntent.minutes = -1
              do {
                _ = try await timerIntent.perform()
                smokeLog("Sleep timer accepted a negative duration")
                return
              } catch AmperfyAppIntentError.invalidSleepTimerDuration {}
              self.appDelegate.activateSleepTimer(timeInterval: 0.15)
              self.appDelegate.activateSleepTimer(timeInterval: 5)
              try await Task.sleep(for: .milliseconds(350))
              guard self.appDelegate.player.isPlaying else { return }
              self.appDelegate.activateSleepTimer(timeInterval: 0.15)
              try await Task.sleep(for: .milliseconds(350))
              guard !self.appDelegate.player.isPlaying, self.appDelegate.sleepTimer == nil else { return }
              smokeLog("Favorites shuffle and sleep timer shortcuts passed; cancellation and replacement preserved playback")
              let marker = URL.documentsDirectory.appendingPathComponent("player-smoke-ready")
              try "ready".write(to: marker, atomically: true, encoding: .utf8)
            } catch { smokeLog("Player smoke failed: \(error)") }
            return
          }
          let marker = URL.documentsDirectory.appendingPathComponent("login-smoke-ready")
          try? "ready".write(to: marker, atomically: true, encoding: .utf8)
        }
      }
    #endif
  }

  /** Called when the user activates your application by selecting a shortcut on the Home Screen,
       and the window scene is already connected.
   */
  /// - Tag: PerformAction
  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> ()
  ) {
    os_log("windowScene shortcutItem", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return completionHandler(false)
    }
    let handled = appDelegate.quickActionsManager.handleShortCutItem(shortcutItem: shortcutItem)
    completionHandler(handled)
  }

  func sceneDidDisconnect(_ scene: UIScene) {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not neccessarily discarded (see `application:didDiscardSceneSessions` instead).
    os_log("sceneDidDisconnect", log: self.log, type: .info)
    appDelegate.rebuildMainMenu()
  }

  func sceneDidBecomeActive(_ scene: UIScene) {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    os_log("sceneDidBecomeActive", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    appDelegate.quickActionsManager.handleSavedShortCutItemIfSaved()
    appDelegate.rebuildMainMenu()
  }

  func sceneWillResignActive(_ scene: UIScene) {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
    os_log("sceneWillResignActive", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    appDelegate.quickActionsManager.configureQuickActions()
  }

  func sceneWillEnterForeground(_ scene: UIScene) {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
    os_log("sceneWillEnterForeground", log: self.log, type: .info)
    AmperKit.shared.threadPerformanceMonitor.isInForeground = true
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.

    // Save changes in the application's managed object context when the application transitions to the background.
    os_log("sceneDidEnterBackground", log: self.log, type: .info)
    AmperKit.shared.threadPerformanceMonitor.isInForeground = false
    guard appDelegate.isNormalInteraction else {
      return
    }
    appDelegate.scheduleAppRefresh()
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    os_log("openURLContexts", log: self.log, type: .info)
    guard appDelegate.isNormalInteraction else {
      return
    }
    for URLContext in URLContexts {
      _ = appDelegate.intentManager.handleIncoming(url: URLContext.url)
    }
  }

  // This is the NSUserActivity that will be used to restore state when the Scene reconnects.
  // It can be the same activity used for handoff or spotlight, or it can be a separate activity
  // with a different activity type and/or userInfo.
  // After this method is called, and before the activity is actually saved in the restoration file,
  // if the returned NSUserActivity has a delegate (NSUserActivityDelegate), the method
  // userActivityWillSave is called on the delegate. Additionally, if any UIResponders
  // have the activity set as their userActivity property, the UIResponder updateUserActivityState
  // method is called to update the activity. This is done synchronously and ensures the activity
  // has all info filled in before it is saved.
  func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    os_log("stateRestorationActivity", log: self.log, type: .info)
    return nil
  }

  // This will be called after scene connection, but before activation, and will provide the
  // activity that was last supplied to the stateRestorationActivityForScene callback, or
  // set on the UISceneSession.stateRestorationActivity property.
  // Note that, if it's required earlier, this activity is also already available in the
  // UISceneSession.stateRestorationActivity at scene connection time.
  func scene(
    _ scene: UIScene,
    restoreInteractionStateWith stateRestorationActivity: NSUserActivity
  ) {
    os_log("restoreInteractionStateWith", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, willContinueUserActivityWithType userActivityType: String) {
    os_log("willContinueUserActivityWithType", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    os_log(
      "scene launch via userActivity: %s",
      log: self.log,
      type: .info,
      userActivity.activityType
    )
  }

  func scene(
    _ scene: UIScene,
    didFailToContinueUserActivityWithType userActivityType: String,
    error: Error
  ) {
    os_log("didFailToContinueUserActivityWithType", log: self.log, type: .info)
  }

  func scene(_ scene: UIScene, didUpdate userActivity: NSUserActivity) {
    os_log("didUpdate userActivity: %s", log: self.log, type: .info, userActivity.activityType)
  }
}
