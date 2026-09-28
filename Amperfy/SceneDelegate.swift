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
import AVFAudio
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
              newLyricCell.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
              newLyricCell.layoutIfNeeded()
              lyricModel.isActiveLine = false
              newLyricCell.refresh()
              guard let blurredLyric = newLyricCell.contentView.subviews.compactMap({ $0 as? UIImageView }).first,
                    blurredLyric.image != nil, blurredLyric.alpha > 0 else {
                smokeLog("Inactive lyrics did not produce a visible blurred text layer")
                return
              }
              lyricModel.isActiveLine = true
              newLyricCell.refresh()
              guard blurredLyric.alpha == 0 else {
                smokeLog("Active lyric retained its blurred text layer")
                return
              }
              smokeLog("Inactive lyrics blur and active-line clarity passed after cell replacement")
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
              var playerPolishChecksPassed = true
              let outputSymbols: [(AVAudioSession.Port, String, String)] = [
                (.bluetoothA2DP, "JYQ 的 AirPods", "airpods.gen3"),
                (.bluetoothA2DP, "airpods", "airpods.gen3"),
                (.bluetoothA2DP, "AirPods 4", "airpods.gen3"),
                (.bluetoothHFP, "AirPods 3", "airpods.gen3"),
                (.bluetoothA2DP, "AirPods 2", "airpods"),
                (.bluetoothHFP, "AirPods Pro 2", "airpodspro"),
                (.bluetoothLE, "AIRPODS MAX", "airpodsmax"),
                (.bluetoothA2DP, "My renamed headset", "airplay.audio"),
                (.builtInSpeaker, "AirPods Pro", "airplay.audio"),
                (.headphones, "Headphones", "headphones"),
                (.airPlay, "Living room", "airplay.audio"),
              ]
              guard outputSymbols.allSatisfy({ port, name, expected in
                PlayerControlView.audioOutputSymbol(portType: port, portName: name) == expected &&
                  UIImage(systemName: expected) != nil
              }) else {
                smokeLog("Audio output icon mapping or system symbol availability failed")
                return
              }
              smokeLog("AirPods, Pro, Max and fallback audio output symbols passed")
              if let tabHost = vc as? TabBarVC {
                tabHost.view.layoutIfNeeded()
                guard let dock = tabHost.playerDock, tabHost.bottomAccessory == nil,
                      !tabHost.isTabBarHidden else {
                  smokeLog("Phone player is not using the custom floating dock")
                  return
                }
                dock.layoutIfNeeded()
                guard tabHost.tabBar.items?.count == 3,
                      tabHost.tabBar.superview !== dock,
                      dock.navigationGlass.isHidden, dock.searchGlass.isHidden else {
                  smokeLog("Dock did not restore a full-height system tab bar")
                  return
                }
                let expandedFrame = miniPlayer.glassContainer.frame
                let nativeTop = tabHost.tabBar.convert(tabHost.tabBar.bounds, to: tabHost.view).minY
                let playerBottom = miniPlayer.glassContainer.convert(miniPlayer.glassContainer.bounds, to: tabHost.view).maxY
                guard abs(nativeTop - playerBottom - 12) < 0.5,
                      !dock.point(inside: CGPoint(x: dock.bounds.midX, y: dock.bounds.maxY - 20), with: nil) else {
                  smokeLog("System navigation gap or native tab touch passthrough is incorrect")
                  return
                }
                smokeLog("Original system tab bar restored: \(tabHost.tabBar.frame), player gap \(nativeTop - playerBottom)")
                guard abs(expandedFrame.height - 56) < 0.5,
                      abs(dock.navigationGlass.frame.minY - expandedFrame.maxY - 12) < 0.5,
                      abs(miniPlayer.bounds.height - 56) < 0.5,
                      !dock.point(inside: CGPoint(x: dock.bounds.midX, y: expandedFrame.maxY + 6), with: nil) else {
                  smokeLog("Player height, external 12pt gap or gap hit testing is incorrect")
                  return
                }
                func dockScreenshot(_ name: String) throws {
                  let image = UIGraphicsImageRenderer(bounds: tabHost.view.bounds).image { _ in
                    tabHost.view.drawHierarchy(in: tabHost.view.bounds, afterScreenUpdates: true)
                  }
                  try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name))
                }
                try dockScreenshot("player-mini-spacing.png")
                tabHost.updatePlayerDockForScroll(delta: -40, atTop: false)
                try await Task.sleep(for: .milliseconds(650))
                let compactFrame = miniPlayer.glassContainer.frame
                guard dock.isCollapsed, tabHost.isTabBarHidden, abs(compactFrame.height - 48) < 0.5,
                      abs(compactFrame.midY - dock.navigationGlass.frame.midY) < 0.5,
                      abs(compactFrame.minX - dock.navigationGlass.frame.maxX - 12) < 0.5,
                      abs(dock.searchGlass.frame.minX - compactFrame.maxX - 12) < 0.5,
                      miniPlayer.glassContainer.superview === dock else {
                  smokeLog("Sinking player did not settle between navigation and search")
                  return
                }
                try dockScreenshot("player-mini-collapsed.png")
                // Reverse while the spring is moving, then return to the top.
                tabHost.updatePlayerDockForScroll(delta: 25, atTop: false)
                try await Task.sleep(for: .milliseconds(80))
                tabHost.updatePlayerDockForScroll(delta: -40, atTop: false)
                try await Task.sleep(for: .milliseconds(80))
                tabHost.updatePlayerDockForScroll(delta: 0, atTop: true)
                try await Task.sleep(for: .milliseconds(650))
                guard !dock.isCollapsed, !tabHost.isTabBarHidden, miniPlayer.glassContainer.frame == expandedFrame,
                      !miniPlayer.artworkImage.isHidden else {
                  smokeLog("Quick dock reversal or top-of-list expansion changed the player geometry")
                  return
                }
                smokeLog("Custom dock: 56pt player, 12pt external gap, 48pt sinking, reversal and gap hit testing passed")
              }
              func descendants(of view: UIView) -> [UIView] {
                view.subviews + view.subviews.flatMap { descendants(of: $0) }
              }
              func flyingCover() -> UIView? {
                miniPlayer.window.flatMap { window in
                  descendants(of: window).first { $0.accessibilityIdentifier == "player-surface-transition-artwork" }
                }
              }
              miniPlayer.beginPlayerExpansion()
              try await Task.sleep(for: .milliseconds(80))
              guard let cancelledPopup = vc.presentedViewController as? PopupPlayerVC else {
                smokeLog("Upward expansion did not present the player")
                return
              }
              miniPlayer.updatePlayerExpansion(translation: 110)
              try await Task.sleep(for: .milliseconds(80))
              miniPlayer.endPlayerExpansion(translation: 110, velocity: -200, cancelled: true)
              try await Task.sleep(for: .seconds(1))
              guard vc.presentedViewController !== cancelledPopup,
                    cancelledPopup.presentingViewController == nil, cancelledPopup.view.mask == nil,
                    miniPlayer.glassContainer.layer.opacity == 1,
                    miniPlayer.artworkImage.layer.opacity == 1, flyingCover() == nil else {
                smokeLog("Cancelled upward expansion did not restore mini player")
                return
              }
              smokeLog("Upward expansion cancellation restored mini player")
              // Returning home can show its first-run sync tip after the player is gone.
              // Clear that unrelated modal before testing another upward gesture.
              if vc.presentedViewController != nil {
                vc.dismiss(animated: false)
                try await Task.sleep(for: .milliseconds(100))
              }
              // Reproduce the reported paused/dark-mode frames, including a
              // metadata refresh while the shared cover is still in flight.
              let originalAppearance = vc.overrideUserInterfaceStyle
              vc.overrideUserInterfaceStyle = .dark
              self.appDelegate.player.pause()
              try await Task.sleep(for: .milliseconds(550))
              miniPlayer.beginPlayerExpansion()
              try await Task.sleep(for: .milliseconds(80))
              guard let pausedPopup = vc.presentedViewController as? PopupPlayerVC else { return }
              let pausedDistance = (miniPlayer.window?.bounds.height ?? 800) * 0.6
              miniPlayer.updatePlayerExpansion(translation: pausedDistance * 0.85)
              pausedPopup.refreshCurrentlyPlayingInfoView()
              try await Task.sleep(for: .milliseconds(100))
              guard let hiddenCover = pausedPopup.transitionArtwork,
                    hiddenCover.mask?.accessibilityIdentifier == "player-transition-artwork-mask",
                    hiddenCover.mask?.alpha == 0,
                    miniPlayer.artworkImage.mask?.alpha == 0, flyingCover() != nil else {
                smokeLog("A refresh exposed the real cover during paused opening")
                return
              }
              guard PlayerControlView.audioOutputSymbol(portType: .bluetoothA2DP, portName: "Renamed",
                                                        preferredSymbol: "airpods.gen3") == "airpods.gen3",
                    PlayerControlView.audioOutputSymbol(portType: .builtInSpeaker, portName: "iPhone",
                                                        preferredSymbol: "airpods.gen3") == "airplay.audio" else { return }
              func transitionScreenshot(_ name: String) throws {
                guard let window = miniPlayer.window else { return }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                  window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent(name))
              }
              try transitionScreenshot("player-opening-refreshed.png")
              miniPlayer.endPlayerExpansion(translation: pausedDistance * 0.85, velocity: 850)
              try await Task.sleep(for: .seconds(1))
              guard hiddenCover.mask == nil, miniPlayer.artworkImage.mask == nil,
                    abs(hiddenCover.transform.a - 0.82) < 0.01, flyingCover() == nil else {
                smokeLog("Paused opening did not hand off to the real scaled cover")
                return
              }
              pausedPopup.beginInteractiveDismissal()
              try await Task.sleep(for: .milliseconds(80))
              let closingDistance = pausedPopup.view.bounds.height
              pausedPopup.updateInteractiveDismissal(translation: closingDistance * 0.93)
              pausedPopup.refreshCurrentlyPlayingInfoView()
              pausedPopup.controlView?.refreshView()
              try await Task.sleep(for: .milliseconds(100))
              guard let controlsMask = pausedPopup.controlPlaceholderView.mask,
                    controlsMask.accessibilityIdentifier == "player-transition-content-mask",
                    (controlsMask.layer.presentation()?.opacity ?? controlsMask.layer.opacity) < 0.01,
                    (pausedPopup.view.layer.presentation()?.opacity ?? 1) < 0.01,
                    miniPlayer.glassContainer.layer.opacity == 1,
                    hiddenCover.mask?.alpha == 0, flyingCover() != nil else {
                smokeLog("Fullscreen controls remained visible over the live mini player during closing")
                return
              }
              try transitionScreenshot("player-closing-capsule.png")
              pausedPopup.endInteractiveDismissal(translation: closingDistance * 0.93, velocity: -200, cancelled: true)
              try await Task.sleep(for: .seconds(1))
              guard pausedPopup.view.alpha == 1, pausedPopup.view.mask == nil,
                    pausedPopup.controlPlaceholderView.mask == nil,
                    hiddenCover.mask == nil, miniPlayer.artworkImage.mask == nil,
                    flyingCover() == nil else {
                smokeLog("Reversing the final closing phase did not restore all content masks")
                return
              }
              smokeLog("Paused opening refresh kept one cover; closing hid fullscreen controls and restored live mini player; reversal restored masks")
              pausedPopup.dismiss(animated: false)
              try await Task.sleep(for: .milliseconds(150))
              if vc.presentedViewController != nil {
                vc.dismiss(animated: false)
                try await Task.sleep(for: .milliseconds(100))
              }
              vc.overrideUserInterfaceStyle = originalAppearance
              self.appDelegate.player.play()
              try await Task.sleep(for: .milliseconds(550))
              miniPlayer.beginPlayerExpansion()
              try await Task.sleep(for: .milliseconds(80))
              miniPlayer.updatePlayerExpansion(translation: 160)
              try await Task.sleep(for: .milliseconds(80))
              guard let cover = flyingCover(), let coverHost = cover.superview,
                    let coverFrame = cover.layer.presentation()?.frame,
                    let openingPopup = vc.presentedViewController as? PopupPlayerVC,
                    openingPopup.transitionArtwork?.mask?.alpha == 0 else {
                smokeLog("Opening did not create a shared moving album cover")
                return
              }
              let miniCoverFrame = miniPlayer.artworkImage.convert(miniPlayer.artworkImage.bounds, to: coverHost)
              guard coverFrame.width > miniCoverFrame.width + 1,
                    coverFrame.midY < miniCoverFrame.midY - 1 else {
                smokeLog("Held opening gesture did not move and enlarge the mini-player cover: \(coverFrame)")
                return
              }
              smokeLog("Shared album cover moved from \(miniCoverFrame) to held frame \(coverFrame)")
              // Capture the held gesture before release. Rendering system glass can
              // stall the main thread and hide the short rebound from frame sampling.
              if let window = miniPlayer.window {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                  window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                try image.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-opening.png"))
              }
              miniPlayer.endPlayerExpansion(translation: 160, velocity: 850)
              // UIKit may defer presentation until the next run-loop turn. Sample frames
              // throughout the transition instead of assuming one fixed scheduling delay.
              var sampledSurfaceExpansion = false
              var sampledSpringOvershoot = false
              var sampledContentRebound = false
              var largestOpeningHeight: CGFloat = 0
              var lastSample = "no transition surface"
              for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                guard let popup = vc.presentedViewController as? PopupPlayerVC,
                      let surface = popup.view.mask,
                      surface.accessibilityIdentifier == "player-transition-surface",
                      let animatedFrame = surface.layer.presentation()?.frame else { continue }
                let destinationHeight = popup.view.bounds.height
                guard popup.view.layer.opacity == 1, popup.view.alpha == 1,
                      popup.view.bounds.size == popup.view.window?.bounds.size else {
                  smokeLog("Live player was hidden or resized during opening")
                  return
                }
                popup.refreshCurrentlyPlayingInfoView()
                guard popup.transitionArtwork?.mask?.alpha == 0 else {
                  smokeLog("Live metadata refresh exposed a second cover during the opening spring")
                  return
                }
                lastSample = "height \(animatedFrame.height), destination \(destinationHeight)"
                largestOpeningHeight = max(largestOpeningHeight, animatedFrame.height)
                if animatedFrame.height > destinationHeight + 0.5 { sampledSpringOvershoot = true }
                if let layer = popup.view.layer.presentation(), layer.transform.m11 > 1.002 {
                  sampledContentRebound = true
                }
                if animatedFrame.height > miniPlayer.glassContainer.bounds.height + 10,
                   animatedFrame.height < destinationHeight - 1 { sampledSurfaceExpansion = true }
              }
              guard sampledSurfaceExpansion, let popup = vc.presentedViewController as? PopupPlayerVC else {
                smokeLog("Whole-player expansion did not interpolate: \(lastSample)")
                return
              }
              smokeLog("Whole player expanded from the mini-player capsule: \(lastSample)")
              if !sampledSpringOvershoot || !sampledContentRebound {
                smokeLog("Whole player did not rebound on opening: largest height \(largestOpeningHeight), \(lastSample)")
                playerPolishChecksPassed = false
              } else {
                smokeLog("Complete player surface and live content spring overshoot sampled before settling")
              }
              try await Task.sleep(for: .seconds(1))
              guard popup.largePlayerPlaceholderView.transform == .identity,
                    popup.transitionArtwork?.isHidden == false,
                    popup.transitionArtwork?.layer.opacity == 1, popup.transitionArtwork?.mask == nil,
                    flyingCover() == nil else { return }
              popup.beginInteractiveDismissal()
              try await Task.sleep(for: .milliseconds(80))
              popup.updateInteractiveDismissal(translation: 70)
              try await Task.sleep(for: .milliseconds(80))
              popup.endInteractiveDismissal(translation: 70, velocity: -150, cancelled: true)
              try await Task.sleep(for: .seconds(1))
              guard vc.presentedViewController === popup, popup.view.transform == .identity,
                    popup.transitionArtwork?.isHidden == false, popup.view.layer.opacity == 1, popup.view.mask == nil,
                    popup.transitionArtwork?.layer.opacity == 1,
                    miniPlayer.artworkImage.layer.opacity == 1, flyingCover() == nil else {
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
              if let controls = popup.controlView {
                controls.renderAudioOutput(.init(portType: .bluetoothA2DP, name: "airpods", uid: "smoke-airpods4"))
                controls.refreshPlayer()
                controls.renderAudioOutput(nil, settled: false)
                controls.renderAudioOutput(.init(portType: .builtInSpeaker, name: "iPhone", uid: "speaker"), settled: false)
                controls.renderAudioOutput(.init(portType: .bluetoothHFP, name: "Bluetooth", uid: "smoke-airpods4"))
                guard controls.audioOutputIconName == "airpods.gen3",
                      controls.airplayButton.menu != nil else {
                  smokeLog("Playback refresh or empty route reset the AirPods 4 icon")
                  return
                }
                controls.renderAudioOutput(.init(portType: .builtInSpeaker, name: "iPhone", uid: "speaker"))
                guard controls.audioOutputIconName == "airplay.audio", controls.airplayButton.menu == nil else { return }
                smokeLog("AirPods 3/4 symbol, model override, refresh stability and real disconnect reset passed")
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
              try await Task.sleep(for: .milliseconds(700))
              guard abs(fullPlayer.artworkImage.transform.a - 0.82) < 0.01,
                    fullPlayer.compactHeader.transform == .identity else {
                smokeLog("Pausing did not shrink only the large artwork")
                return
              }
              try screenshot("player-paused-artwork.png")
              self.appDelegate.player.play()
              try await Task.sleep(for: .milliseconds(800))
              guard fullPlayer.artworkImage.transform == .identity else {
                smokeLog("Resuming did not restore artwork scale")
                return
              }
              self.appDelegate.player.pause()
              self.appDelegate.player.seek(toSecond: 42)
              guard popup.controlView?.optionsStackView.arrangedSubviews.compactMap({ $0 as? UIButton })
                .contains(where: { $0.accessibilityLabel == "Player options".localized }) == false,
                fullPlayer.optionsButton.menu != nil else {
                smokeLog("Player options were not consolidated into the top menu")
                return
              }
              smokeLog("Pause/resume artwork scale and single top options menu passed")
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
              // The same header instances and screen rectangles must survive
              // every frame, including reversal, scrolling and immersive layout.
              guard let largeView = popup.largeCurrentlyPlayingView else { return }
              let fixedElements = [largeView.compactHeader] + largeView.compactHeaderElements
              let fixedFrames = fixedElements.map { $0.convert($0.bounds, to: popup.view) }
              @MainActor func compactHeaderStayedFixed(samples: Int = 22) async throws -> Bool {
                for _ in 0..<samples {
                  try await Task.sleep(for: .milliseconds(16))
                  let elements = [largeView.compactHeader] + largeView.compactHeaderElements
                  guard elements.count == fixedElements.count,
                        !largeView.compactHeader.isHidden,
                        largeView.compactHeader.alpha == 1,
                        !descendants(of: popup.view).contains(where: {
                          $0.accessibilityIdentifier == "player-layout-transition-artwork"
                        }) else { return false }
                  for (index, element) in elements.enumerated() {
                    guard element === fixedElements[index], !element.isHidden, element.alpha == 1 else { return false }
                    let layer = element.layer.presentation() ?? element.layer
                    let frame = layer.convert(layer.bounds, to: popup.view.layer.presentation() ?? popup.view.layer)
                    let expected = fixedFrames[index]
                    guard abs(frame.minX - expected.minX) < 0.5,
                          abs(frame.minY - expected.minY) < 0.5,
                          abs(frame.width - expected.width) < 0.5,
                          abs(frame.height - expected.height) < 0.5 else {
                      smokeLog("Compact header moved: element \(index), \(frame), expected \(expected)")
                      return false
                    }
                  }
                }
                return true
              }
              popup.controlView?.displayPlaylistPressed()
              guard try await compactHeaderStayedFixed(),
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .compact else {
                smokeLog("Lyrics to queue moved the fixed header")
                return
              }
              try screenshot("player-queue-from-lyrics.png")
              let queueOffset = popup.tableView.contentOffset
              popup.tableView.setContentOffset(CGPoint(x: 0, y: queueOffset.y + 60), animated: false)
              guard try await compactHeaderStayedFixed(samples: 3) else { return }
              popup.tableView.setContentOffset(queueOffset, animated: false)
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              guard try await compactHeaderStayedFixed(),
                    largeView.isDisplayingLyrics,
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .large else {
                smokeLog("Queue to lyrics moved the fixed header")
                return
              }
              try screenshot("player-lyrics-from-queue.png")
              for _ in 0..<3 {
                popup.controlView?.displayPlaylistPressed()
                guard try await compactHeaderStayedFixed(samples: 3) else { return }
                popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
                guard try await compactHeaderStayedFixed(samples: 3) else { return }
              }
              popup.setLyricsControlsHidden(true)
              guard try await compactHeaderStayedFixed() else { return }
              popup.controlView?.displayPlaylistPressed()
              guard try await compactHeaderStayedFixed() else { return }
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              guard try await compactHeaderStayedFixed() else { return }
              smokeLog("Shared header identity, position and size stayed fixed through switching, reversal, queue scrolling and immersive controls")
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
              var sampledClosingRebound = false
              var sampledReturningCover = false
              for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                guard let surface = popup.view.mask,
                      let animatedFrame = surface.layer.presentation()?.frame else { continue }
                let destination = miniPlayer.glassContainer.bounds
                if animatedFrame.height < destination.height - 0.25 { sampledClosingRebound = true }
                if let cover = flyingCover(), let frame = cover.layer.presentation()?.frame,
                   frame.width > miniPlayer.artworkImage.bounds.width + 1,
                   frame.width < CurrentlyPlayingTableCell.artworkSide - 1 {
                  sampledReturningCover = true
                }
              }
              if !sampledClosingRebound {
                smokeLog("Released downward gesture never produced a spring rebound")
                playerPolishChecksPassed = false
              } else {
                smokeLog("Released downward gesture spring rebound sampled before settling")
              }
              // Returning home can present the first-run welcome message. Check the
              // player's own presentation relationship, not whether every modal is gone.
              guard vc.presentedViewController !== popup, popup.presentingViewController == nil,
                    sampledReturningCover, flyingCover() == nil,
                    miniPlayer.artworkImage.layer.opacity == 1 else {
                smokeLog("Quick downward drag did not dismiss the player")
                return
              }
              smokeLog("Whole-player capsule morph, shared cover flight in both directions, cancellation and quick dismissal passed")
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
              if let tabHost = vc as? TabBarVC, let dock = tabHost.playerDock {
                dock.onSearch?()
                for _ in 0..<30 {
                  try await Task.sleep(for: .milliseconds(100))
                  tabHost.view.layoutIfNeeded()
                  if tabHost.searchViewController?.searchController.searchBar.searchTextField.isFirstResponder == true,
                     dock.isHidden { break }
                }
                let search = tabHost.searchViewController
                let searchFocused = search?.searchController.searchBar.searchTextField.isFirstResponder == true
                guard tabHost.selectedTab is UISearchTab, searchFocused, dock.isHidden else {
                  smokeLog("Custom search navigation failed: controller=\(String(describing: search)), loaded=\(search?.isViewLoaded == true), active=\(search?.searchController.isActive == true), focused=\(searchFocused), dockHidden=\(dock.isHidden)")
                  return
                }
                let searchImage = UIGraphicsImageRenderer(bounds: tabHost.view.bounds).image { _ in
                  tabHost.view.drawHierarchy(in: tabHost.view.bounds, afterScreenUpdates: true)
                }
                try searchImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-search-keyboard.png"))
                // iOS can host the native tab search field outside the tab
                // controller's view, so end editing on the actual responder.
                search?.searchController.searchBar.searchTextField.resignFirstResponder()
                tabHost.view.window?.endEditing(true)
                for _ in 0..<30 {
                  try await Task.sleep(for: .milliseconds(100))
                  tabHost.view.layoutIfNeeded()
                  if !dock.isHidden { break }
                }
                guard !dock.isHidden,
                      search?.searchController.searchBar.searchTextField.isFirstResponder != true else {
                  smokeLog("Custom dock did not return after dismissing the keyboard")
                  return
                }
                tabHost.selectedTab = tabHost.tabs.first(where: { $0.identifier == "Tabs.Home" })
                tabHost.view.layoutIfNeeded()
                guard tabHost.selectedTab?.identifier == "Tabs.Home", !dock.isCollapsed else { return }
                smokeLog("Custom navigation, search keyboard hiding and restoration passed")
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
              guard playerPolishChecksPassed else { return }
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
