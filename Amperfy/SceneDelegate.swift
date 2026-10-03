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
import MediaPlayer
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
  #if DEBUG && targetEnvironment(simulator)
    private var resourceProfilePhase = ""
  #endif

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
      if ProcessInfo.processInfo.arguments.contains("--smoke-resource-profile"),
         vc is MainSceneHostingViewController {
        Task { @MainActor in await self.runPlayerResourceProfile(on: vc) }
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-login"),
         vc is MainSceneHostingViewController {
        Task { @MainActor in
          // Allow view loading, initial home requests and artwork downloads to complete.
          try? await Task.sleep(for: .seconds(10))
          guard let activeAccount = self.appDelegate.storage.settings.accounts.active,
                self.appDelegate.storage.settings.accounts.getSetting(activeAccount).read
                  .initialSyncCompletionStatus == .completed else { return }
          if ProcessInfo.processInfo.arguments.contains("--smoke-player") {
            defer {
              let ready = URL.documentsDirectory.appendingPathComponent("player-smoke-ready")
              if !FileManager.default.fileExists(atPath: ready.path) {
                try? Data("Player checks failed\n".utf8).write(to:
                  URL.documentsDirectory.appendingPathComponent("player-smoke-failed"))
              }
            }
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
              miniPlayer.layoutIfNeeded()
              guard miniPlayer.clipsToBounds,
                    abs(miniPlayer.layer.cornerRadius - miniPlayer.bounds.height / 2) < 0.5,
                    !miniPlayer.subviews.contains(where: { $0 is SeekableTimeSlider }) else {
                smokeLog("Mini player content or progress escaped its capsule")
                return
              }
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
                guard tabHost.tabBar.items?.count == 4,
                      tabHost.tabBar.superview !== dock,
                      tabHost.tabBar.alpha == 1, tabHost.tabBar.isUserInteractionEnabled,
                      !tabHost.tabBar.accessibilityElementsHidden,
                      dock.navigationSlot.isHidden, dock.searchSlot.isHidden,
                      tabHost.tabBar.itemPositioning == .fill else {
                  smokeLog("Native tab bar was hidden, disabled or covered by custom navigation")
                  return
                }
                let expandedFrame = miniPlayer.glassContainer.frame
                let nativeTop = tabHost.tabBar.convert(tabHost.tabBar.bounds, to: tabHost.view).minY
                let playerBottom = miniPlayer.glassContainer.convert(miniPlayer.glassContainer.bounds, to: tabHost.view).maxY
                guard abs(nativeTop - playerBottom - 12) < 0.5,
                      !dock.point(inside: CGPoint(x: dock.bounds.midX, y: dock.bounds.maxY - 20), with: nil) else {
                  smokeLog("Player gap or native tab touch passthrough is incorrect")
                  return
                }
                let nativePoint = tabHost.tabBar.convert(CGPoint(x: tabHost.tabBar.bounds.width * 0.25,
                  y: 25), to: tabHost.view)
                guard let hit = tabHost.view.hitTest(nativePoint, with: nil),
                      hit === tabHost.tabBar || hit.isDescendant(of: tabHost.tabBar) else {
                  smokeLog("Navigation touches do not reach the system tab bar")
                  return
                }
                smokeLog("Native glass tab bar receives navigation touches; item width \(tabHost.tabBar.itemWidth), player gap \(nativeTop - playerBottom)")
                guard abs(expandedFrame.height - 56) < 0.5,
                      abs(dock.navigationSlot.frame.minY - expandedFrame.maxY - 12) < 0.5,
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
                guard let home = tabHost.tabs.first(where: { $0.identifier == "Tabs.Home" }),
                      let library = tabHost.tabs.first(where: { $0.identifier == "Tabs.Library" }) else { return }
                tabHost.selectedTab = library
                tabHost.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(900))
                guard tabHost.selectedTab === library, tabHost.tabBar.alpha == 1,
                      !dock.point(inside: CGPoint(x: dock.bounds.midX, y: dock.bounds.maxY - 20), with: nil) else { return }
                try dockScreenshot("player-native-library.png")
                tabHost.selectedTab = home
                tabHost.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(900))
                guard tabHost.selectedTab === home, tabHost.tabBar.alpha == 1 else { return }
                smokeLog("Home and Library selection uses the visible native tab bar without a custom glass overlay")
                tabHost.updatePlayerDockForScroll(delta: -40, atTop: false)
                try await Task.sleep(for: .milliseconds(650))
                let compactFrame = miniPlayer.glassContainer.frame
                guard dock.isCollapsed, tabHost.isTabBarHidden, abs(compactFrame.height - 48) < 0.5,
                      abs(compactFrame.midY - dock.navigationSlot.frame.midY) < 0.5,
                      abs(compactFrame.minX - dock.navigationSlot.frame.maxX - 12) < 0.5,
                      abs(dock.searchSlot.frame.minX - compactFrame.maxX - 12) < 0.5,
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
              func renderedSurface(_ popup: PopupPlayerVC) -> CGRect? {
                guard let maskView = popup.view.mask else { return nil }
                let page = popup.view.layer.presentation() ?? popup.view.layer
                let mask = maskView.layer.presentation() ?? maskView.layer
                let sx = page.frame.width / popup.view.bounds.width
                let sy = page.frame.height / popup.view.bounds.height
                return CGRect(x: page.frame.minX + mask.frame.minX * sx,
                              y: page.frame.minY + mask.frame.minY * sy,
                              width: mask.frame.width * sx, height: mask.frame.height * sy)
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
              miniPlayer.updatePlayerExpansion(translation: pausedDistance * 0.30)
              try await Task.sleep(for: .milliseconds(100))
              if let earlyFrame = renderedSurface(pausedPopup),
                    earlyFrame.height > miniPlayer.glassContainer.bounds.height + 20,
                    earlyFrame.height < pausedPopup.view.bounds.height - 20,
                    earlyFrame.width > miniPlayer.glassContainer.bounds.width + 1,
                    earlyFrame.width < pausedPopup.view.bounds.width - 1,
                    (pausedPopup.view.layer.presentation()?.opacity ?? pausedPopup.view.layer.opacity) > 0.98,
                    let earlyContent = pausedPopup.controlPlaceholderView.mask?.layer.presentation(),
                    earlyContent.opacity > 0.5 {
                smokeLog("Interactive opening surface and foreground are visible")
              } else {
                smokeLog("Opening checkpoint: surface \(String(describing: renderedSurface(pausedPopup))), bounds \(pausedPopup.view.bounds), mini \(miniPlayer.glassContainer.bounds), opacity \(pausedPopup.view.layer.opacity), rendered opacity \(String(describing: pausedPopup.view.layer.presentation()?.opacity)), content \(String(describing: pausedPopup.controlPlaceholderView.mask?.layer.presentation()?.opacity))")
                playerPolishChecksPassed = false
              }
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
              @MainActor @Sendable func compositorScreenshot(_ name: String) async throws {
                let request = URL.documentsDirectory.appendingPathComponent("player-screenshot-request")
                let complete = URL.documentsDirectory.appendingPathComponent("player-screenshot-complete")
                try? FileManager.default.removeItem(at: complete)
                try name.write(to: request, atomically: true, encoding: .utf8)
                for _ in 0..<150 {
                  if FileManager.default.fileExists(atPath: complete.path) { return }
                  try await Task.sleep(for: .milliseconds(100))
                }
                throw NSError(domain: "PlayerSmoke", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Simulator screenshot timed out: \(name)"])
              }
              try await compositorScreenshot("player-opening-refreshed.png")
              miniPlayer.endPlayerExpansion(translation: pausedDistance * 0.85, velocity: 850)
              try await Task.sleep(for: .seconds(1))
              guard hiddenCover.mask == nil, miniPlayer.artworkImage.mask == nil,
                    abs(hiddenCover.transform.a - 0.74) < 0.01, flyingCover() == nil else {
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
              if let controlsMask = pausedPopup.controlPlaceholderView.mask,
                    controlsMask.accessibilityIdentifier == "player-transition-content-mask",
                    (controlsMask.layer.presentation()?.opacity ?? controlsMask.layer.opacity) < 0.01,
                    (pausedPopup.view.layer.presentation()?.opacity ?? pausedPopup.view.layer.opacity) > 0.1,
                    miniPlayer.glassContainer.alpha > 0.1,
                    miniPlayer.glassContainer.alpha < 1,
                    miniPlayer.glassContainer.transform.a < 1,
                    hiddenCover.mask?.alpha == 0, flyingCover() != nil {
                smokeLog("Interactive closing capsule handoff is visible")
              } else {
                smokeLog("Closing did not hand off to the animated capsule, or exposed fullscreen controls")
                playerPolishChecksPassed = false
              }
              try await compositorScreenshot("player-closing-capsule.png")
              pausedPopup.endInteractiveDismissal(translation: closingDistance * 0.93, velocity: -200, cancelled: true)
              try await Task.sleep(for: .seconds(1))
              guard pausedPopup.view.alpha == 1, pausedPopup.view.mask == nil,
                    miniPlayer.glassContainer.alpha == 1, miniPlayer.glassContainer.transform == .identity,
                    pausedPopup.controlPlaceholderView.mask == nil,
                    hiddenCover.mask == nil, miniPlayer.artworkImage.mask == nil,
                    flyingCover() == nil else {
                smokeLog("Reversing the final closing phase did not restore all content masks")
                return
              }
              smokeLog("Opening and closing kept the morphing surface visible; refresh kept one cover; capsule hid fullscreen controls; reversal restored masks")
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
                    let openingPopup = vc.presentedViewController as? PopupPlayerVC,
                    openingPopup.transitionArtwork?.mask?.alpha == 0 else {
                smokeLog("Opening did not create a shared moving album cover")
                return
              }
              let coverFrame = (cover.layer.presentation() ?? cover.layer).frame
              guard let openingMotion = openingPopup.surfaceTransition.artworkMotion else { return }
              let miniCoverFrame = openingMotion.startFrame
              let destinationCoverFrame = openingMotion.endFrame
              let sourceSurface = openingMotion.smallFrame
              if let held = renderedSurface(openingPopup) {
                let heightProgress = (held.height - sourceSurface.height) /
                  (openingPopup.view.bounds.height - sourceSurface.height)
                let widthProgress = (held.width - sourceSurface.width) /
                  (openingPopup.view.bounds.width - sourceSurface.width)
                let coverProgress = (coverFrame.width - miniCoverFrame.width) /
                  (destinationCoverFrame.width - miniCoverFrame.width)
                guard abs(heightProgress - widthProgress) < 0.025,
                      abs(heightProgress - coverProgress) < 0.025,
                      abs(held.midY - (sourceSurface.midY +
                        (openingPopup.view.bounds.midY - sourceSurface.midY) * heightProgress)) < 1 else {
                  smokeLog("Held surface did not expand in both axes from the capsule with synchronized artwork")
                  return
                }
              }
              if let title = openingPopup.largeCurrentlyPlayingView?.titleLabel {
                let titleFrame = title.convert(title.bounds, to: coverHost)
                guard titleFrame.minY > coverFrame.maxY,
                      abs(openingPopup.view.transform.a - openingPopup.view.transform.d) < 0.001 else {
                  smokeLog("Opening cover overlapped metadata or distorted control proportions")
                  return
                }
              }
              guard coverFrame.width > miniCoverFrame.width + 1,
                    coverFrame.midY < miniCoverFrame.midY - 1 else {
                smokeLog("Held opening gesture did not move and enlarge the mini-player cover: \(coverFrame)")
                return
              }
              smokeLog("Shared album cover moved from \(miniCoverFrame) to held frame \(coverFrame)")
              // The compositor captures native glass without asking UIKit to redraw
              // a paused transition into a separate graphics context.
              try await compositorScreenshot("player-opening.png")
              miniPlayer.endPlayerExpansion(translation: 160, velocity: 850)
              // UIKit may defer presentation until the next run-loop turn. Sample frames
              // throughout the transition instead of assuming one fixed scheduling delay.
              var sampledSurfaceExpansion = false
              var sampledSpringOvershoot = false
              var sampledContentRebound = false
              var largestOpeningHeight: CGFloat = 0
              var largestContentScale: CGFloat = 1
              var previousCoverWidth = coverFrame.width
              var lastSample = "no transition surface"
              for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                guard let popup = vc.presentedViewController as? PopupPlayerVC,
                      let surface = popup.view.mask,
                      surface.accessibilityIdentifier == "player-transition-surface",
                      let animatedFrame = renderedSurface(popup) else { continue }
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
                if let cover = flyingCover() {
                  let frame = (cover.layer.presentation() ?? cover.layer).frame
                  let pageProgress = min(1, max(0, (animatedFrame.height - sourceSurface.height) /
                    (destinationHeight - sourceSurface.height)))
                  let coverProgress = (frame.width - miniCoverFrame.width) /
                    (destinationCoverFrame.width - miniCoverFrame.width)
                  if pageProgress - coverProgress > 0.025 {
                    smokeLog("Artwork lagged behind the expanding surface: page \(pageProgress), cover \(coverProgress)")
                    playerPolishChecksPassed = false
                  }
                  if frame.width < previousCoverWidth - 0.5 ||
                        frame.width > destinationCoverFrame.width + 0.5 ||
                        frame.minY < destinationCoverFrame.minY - 0.5 {
                    smokeLog("Opening artwork bounced instead of travelling smoothly: \(frame), target \(destinationCoverFrame)")
                    playerPolishChecksPassed = false
                  }
                  previousCoverWidth = frame.width
                }
                let layer = popup.view.layer.presentation() ?? popup.view.layer
                if layer.transform.m22 > 1.012 {
                  largestContentScale = max(largestContentScale, layer.transform.m22)
                  // Model alpha can be 1 while the rendered page is invisible.
                  // The rebound must be visible in both surface and content.
                  if layer.opacity > 0.98,
                     let content = popup.controlPlaceholderView.mask?.layer.presentation(),
                     content.opacity > 0.98 {
                    sampledContentRebound = true
                  }
                }
                if animatedFrame.width > miniPlayer.glassContainer.bounds.width + 1,
                   animatedFrame.width < popup.view.bounds.width - 1,
                   animatedFrame.height > miniPlayer.glassContainer.bounds.height + 10,
                   animatedFrame.height < destinationHeight - 1 { sampledSurfaceExpansion = true }
              }
              guard sampledSurfaceExpansion, var popup = vc.presentedViewController as? PopupPlayerVC else {
                smokeLog("Whole-player expansion did not interpolate: \(lastSample)")
                return
              }
              smokeLog("Whole player expanded from the mini-player capsule: \(lastSample)")
              if !sampledSpringOvershoot || !sampledContentRebound {
                smokeLog("Whole player did not rebound on opening: largest height \(largestOpeningHeight), \(lastSample)")
                playerPolishChecksPassed = false
              } else {
                smokeLog("Complete player surface rebounded visibly (scale \(largestContentScale))")
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
              guard let fullPlayer = popup.largeCurrentlyPlayingView,
                    abs(fullPlayer.titleLabel.font.pointSize - 20) < 0.5,
                    abs(fullPlayer.artistLabel.font.pointSize - 20) < 0.5 else {
                smokeLog("Full player typography no longer matches the reference layout")
                return
              }
              if let controls = popup.controlView {
                #if !targetEnvironment(macCatalyst)
                  let invalidVolumeDrag = RelativeVolumeDrag(value: 0.4, minimum: 0, maximum: 1, width: 0)
                  guard let drag = RelativeVolumeDrag(value: 0.4, minimum: 0, maximum: 1, width: 200),
                        abs(drag.value(forTranslationX: 0) - 0.4) < 0.001,
                        abs(drag.value(forTranslationX: 40) - 0.6) < 0.001,
                        abs(drag.value(forTranslationX: -40) - 0.2) < 0.001,
                        drag.value(forTranslationX: -4000) == 0,
                        drag.value(forTranslationX: 4000) == 1,
                        case nil = invalidVolumeDrag,
                        let volumeControl = descendants(of: controls).compactMap({ $0 as? DragOnlySystemVolumeView }).first else {
                    smokeLog("Relative volume drag jumped at contact or failed directional/limit checks")
                    return
                  }
                  volumeControl.layoutIfNeeded()
                  for x in [CGFloat(1), volumeControl.bounds.width - 1] {
                    guard let hit = volumeControl.hitTest(CGPoint(x: x, y: volumeControl.bounds.midY), with: nil),
                          !(hit is UISlider), hit.superview === volumeControl else {
                      smokeLog("Volume tap reached native slider tracking and could jump to a position")
                      return
                    }
                  }
                  smokeLog("Volume touch-down stayed unchanged; relative left/right drag, bounds and tap interception passed")
                  // The simulator has no functional hardware-volume slider.
                  // Model a native control that lays out again after activation,
                  // without requesting another layout from the player wrapper.
                  let layoutProbe = DragOnlySystemVolumeView(frame: CGRect(x: 0, y: 0, width: 320, height: 32))
                  layoutProbe.isTrackExpansionEnabled = true
                  guard let nativeVolume = descendants(of: layoutProbe).compactMap({ $0 as? MPVolumeView }).first else {
                    smokeLog("System volume is not owned by a separate native view"); return
                  }
                  let nativeSliderProbe = UISlider(frame: layoutProbe.bounds)
                  nativeVolume.insertSubview(nativeSliderProbe, at: 0)
                  layoutProbe.setNeedsLayout()
                  layoutProbe.layoutIfNeeded()
                  for nativeY in [CGFloat(-12), 6, 0, 18, -8] {
                    try await Task.sleep(for: .milliseconds(50))
                    nativeSliderProbe.frame.origin.y = nativeY
                    let nativeFrame = nativeSliderProbe.frame
                    nativeVolume.setNeedsLayout()
                    nativeVolume.layoutIfNeeded()
                    let track = nativeSliderProbe.convert(
                      nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                    guard abs(track.midY - layoutProbe.bounds.midY) < 0.5,
                          nativeSliderProbe.frame == nativeFrame else {
                      smokeLog("Delayed native volume layout moved the track or changed UIKit slider geometry: \(track), \(nativeSliderProbe.frame)")
                      return
                    }
                    layoutProbe.setNeedsLayout()
                    layoutProbe.layoutIfNeeded()
                    let repeatedTrack = nativeSliderProbe.convert(
                      nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                    guard abs(repeatedTrack.midY - layoutProbe.bounds.midY) < 0.5 else {
                      smokeLog("Repeated volume alignment accumulated a vertical offset"); return
                    }
                  }
                  smokeLog("Cold-start and delayed native volume layouts kept the track centered without changing UIKit slider geometry or accumulating offsets")
                  nativeSliderProbe.value = 0.4
                  let restingVolumeTrack = nativeSliderProbe.convert(
                    nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                  let volumeFrameBeforePress = nativeSliderProbe.frame
                  layoutProbe.setTouchPressedForSmoke(true)
                  let activeVolumeTrack = nativeSliderProbe.convert(
                    nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                  let volumeTrackRatio = PlayerTrackSlider.standardActiveTrackHeight /
                    PlayerTrackSlider.standardRestingTrackHeight
                  guard abs(activeVolumeTrack.height - restingVolumeTrack.height * volumeTrackRatio) < 0.5,
                        abs(activeVolumeTrack.midY - layoutProbe.bounds.midY) < 0.5,
                        abs(activeVolumeTrack.width - restingVolumeTrack.width) < 0.5,
                        nativeSliderProbe.frame == volumeFrameBeforePress,
                        abs(nativeSliderProbe.value - 0.4) < 0.001 else {
                    smokeLog("Volume press moved the track, changed volume or failed to expand like the seek bar"); return
                  }
                  nativeSliderProbe.frame.origin.y += 6
                  nativeVolume.setNeedsLayout()
                  nativeVolume.layoutIfNeeded()
                  let relaidActiveTrack = nativeSliderProbe.convert(
                    nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                  guard abs(relaidActiveTrack.midY - layoutProbe.bounds.midY) < 0.5 else {
                    smokeLog("Active volume track lost its center after a native layout"); return
                  }
                  layoutProbe.setTouchPressedForSmoke(false)
                  let releasedVolumeTrack = nativeSliderProbe.convert(
                    nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                  guard abs(releasedVolumeTrack.height - restingVolumeTrack.height) < 0.5,
                        abs(releasedVolumeTrack.midY - layoutProbe.bounds.midY) < 0.5 else {
                    smokeLog("Volume release did not restore the resting track"); return
                  }
                  layoutProbe.setTouchPressedForSmoke(true)
                  layoutProbe.cancelTouchForSmoke()
                  let cancelledVolumeTrack = nativeSliderProbe.convert(
                    nativeSliderProbe.trackRect(forBounds: nativeSliderProbe.bounds), to: layoutProbe)
                  guard abs(cancelledVolumeTrack.height - restingVolumeTrack.height) < 0.5,
                        abs(nativeSliderProbe.value - 0.4) < 0.001 else {
                    smokeLog("Volume cancellation left the track expanded or changed its value"); return
                  }
                  smokeLog("Volume touch expansion matched the seek-bar ratio; release and cancellation restored size; native re-layout kept the center and touch coordinates")
                  let songBeforeVolume = self.appDelegate.player.currentlyPlaying
                  let gainBeforeVolume = self.appDelegate.player.volume
                  let modeBeforeVolume = self.appDelegate.player.playerMode
                  let playingBeforeVolume = self.appDelegate.player.isPlaying
                  controls.refreshPlayer()
                  guard descendants(of: controls).contains(where: { $0 is MPVolumeView }),
                        self.appDelegate.player.volume == gainBeforeVolume,
                        self.appDelegate.player.playerMode == modeBeforeVolume,
                        self.appDelegate.player.currentlyPlaying == songBeforeVolume,
                        self.appDelegate.player.isPlaying == playingBeforeVolume else {
                    smokeLog("Inline system volume control changed application gain, playback or mode")
                    return
                  }
                  smokeLog("Inline native system-volume control preserved application gain and playback; hardware volume requires a physical device")
                #endif
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
              try await compositorScreenshot("player-artwork-landscape.png")
              // Leave enough time for the real engine to preload the second stream.
              self.appDelegate.player.seek(toSecond: 174)
              try await Task.sleep(for: .seconds(9))
              guard self.appDelegate.player.currentlyPlaying == nextSong,
                    popup.largeCurrentlyPlayingView?.titleLabel.text == nextSong.title else {
                smokeLog("Gapless smoke: next audio and displayed song disagree")
                return
              }
              smokeLog("Gapless playback updated song and player title")
              try await compositorScreenshot("player-next-song.png")
              self.appDelegate.player.seek(toSecond: 42)
              try await Task.sleep(for: .seconds(1))
              self.appDelegate.player.pause()
              try await Task.sleep(for: .milliseconds(700))
              guard abs(fullPlayer.artworkImage.transform.a - 0.74) < 0.01,
                    fullPlayer.compactHeader.transform == .identity else {
                smokeLog("Pausing did not shrink only the large artwork")
                return
              }
              try await compositorScreenshot("player-paused-artwork.png")
              guard let controls = popup.controlView else { return }
              controls.playButton.isHighlighted = true
              try await Task.sleep(for: .milliseconds(80))
              try await compositorScreenshot("player-transport-pressed.png")
              controls.playButton.isHighlighted = false
              controls.playButtonPushed(controls.playButton as Any)
              // Capture the short centered symbol exchange inside the app; the
              // external compositor handshake can arrive after it has finished.
              var symbolFrames: [UIImage] = []
              let symbolFrameSize = controls.playButton.bounds.size
              for _ in 0..<12 {
                try await Task.sleep(for: .milliseconds(25))
                symbolFrames.append(UIGraphicsImageRenderer(size: symbolFrameSize).image { _ in
                  controls.playButton.drawHierarchy(in: controls.playButton.bounds, afterScreenUpdates: false)
                })
              }
              let symbolGridSize = CGSize(width: symbolFrameSize.width * 6, height: symbolFrameSize.height * 2)
              let symbolGrid = UIGraphicsImageRenderer(size: symbolGridSize).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(origin: .zero, size: symbolGridSize))
                for (index, frame) in symbolFrames.enumerated() {
                  frame.draw(at: CGPoint(x: CGFloat(index % 6) * symbolFrameSize.width,
                    y: CGFloat(index / 6) * symbolFrameSize.height))
                }
              }
              try symbolGrid.pngData()?.write(to: URL.documentsDirectory
                .appendingPathComponent("player-transport-play-pause-frames.png"))
              try await compositorScreenshot("player-transport-playing-transition.png")
              try await Task.sleep(for: .milliseconds(730))
              guard fullPlayer.artworkImage.transform == .identity else {
                smokeLog("Resuming did not restore artwork scale")
                return
              }
              for _ in 0..<6 {
                controls.playButton.isHighlighted = true
                try await Task.sleep(for: .milliseconds(40))
                controls.playButton.isHighlighted = false
                controls.playButtonPushed(controls.playButton as Any)
                try await Task.sleep(for: .milliseconds(35))
              }
              try await Task.sleep(for: .milliseconds(400))
              guard self.appDelegate.player.isPlaying,
                    (controls.playButton as? PlayerTransportButton)?.isRenderedSymbolSettled == true else {
                smokeLog("Rapid play/pause taps left the visible symbol stale, off-center or unfinished")
                return
              }
              smokeLog("Rapid play/pause taps settled on the current visible symbol without a scale or center offset")
              self.appDelegate.player.pause()
              self.appDelegate.player.seek(toSecond: 42)
              guard popup.controlView?.optionsStackView.arrangedSubviews.compactMap({ $0 as? UIButton })
                .contains(where: { $0.accessibilityLabel == "Player options".localized }) == false,
                fullPlayer.optionsButton.menu != nil else {
                smokeLog("Player options were not consolidated into the top menu")
                return
              }
              smokeLog("Pause/resume artwork scale and single top options menu passed")
              guard let progressSlider = controls.timeSlider as? SeekableTimeSlider else { return }
              let restingProgressTrack = progressSlider.trackRect(forBounds: progressSlider.bounds)
              for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
                progressSlider.setTrackExpandedForSmoke(true)
                controls.didElapsedTimeChange()
                controls.refreshPlayer()
                guard abs(progressSlider.trackRect(forBounds: progressSlider.bounds).height -
                  progressSlider.activeTrackHeight) < 0.1 else {
                  smokeLog("Progress press did not expand or a playback refresh reset the gesture"); return
                }
                progressSlider.sendActions(for: event)
                try await Task.sleep(for: .milliseconds(250))
                let restored = progressSlider.trackRect(forBounds: progressSlider.bounds)
                guard abs(restored.height - restingProgressTrack.height) < 0.1,
                      abs(restored.midY - restingProgressTrack.midY) < 0.1 else {
                  smokeLog("Progress release/cancellation left the track thick or moved its center"); return
                }
              }
              progressSlider.setTrackExpandedForSmoke(true)
              progressSlider.cancelTracking(with: nil)
              guard abs(progressSlider.trackRect(forBounds: progressSlider.bounds).height -
                restingProgressTrack.height) < 0.1,
                    !controls.isSmoothProgressRunning, !popup.isAmbientMotionRunning else {
                smokeLog("Progress cancellation or paused animation cleanup failed"); return
              }
              self.appDelegate.player.continuePlay()
              try await Task.sleep(for: .milliseconds(500))
              guard controls.isSmoothProgressRunning else {
                smokeLog("Visible playback did not start the smooth progress clock"); return
              }
              var progressValues = [Float]()
              for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                progressValues.append(progressSlider.value)
              }
              guard Set(progressValues).count > 3,
                    progressValues.last! > progressValues.first!,
                    abs(Double(progressSlider.value) - self.appDelegate.player.elapsedTime) < 0.25 else {
                smokeLog("Progress still advanced once per second or drifted from the audio engine: \(progressValues)"); return
              }
              let shouldAnimateAmbient = !UIAccessibility.isReduceMotionEnabled &&
                !ProcessInfo.processInfo.isLowPowerModeEnabled
              guard popup.isAmbientMotionRunning == shouldAnimateAmbient else {
                smokeLog("Ambient motion did not follow visible playback/accessibility state"); return
              }
              popup.setPlayerPresentationVisible(false)
              guard !controls.isSmoothProgressRunning, !popup.isAmbientMotionRunning else {
                smokeLog("Hidden player kept its progress clock or background motion running"); return
              }
              popup.setPlayerPresentationVisible(true)
              self.appDelegate.player.pause()
              guard !controls.isSmoothProgressRunning, !popup.isAmbientMotionRunning else {
                smokeLog("Paused player kept smooth progress or background motion running"); return
              }
              try await Task.sleep(for: .milliseconds(100))
              let pausedProgressValue = progressSlider.value
              try await Task.sleep(for: .milliseconds(150))
              guard abs(progressSlider.value - pausedProgressValue) < 0.02 else {
                smokeLog("Progress continued advancing while paused"); return
              }
              smokeLog("Progress restored its thin track after all release/cancel paths; sub-second engine samples, pause and hidden-player animation cleanup passed")
              guard self.appDelegate.player.elapsedTime >= 41 else { return }
              // Exercise real transport actions and the server-empty local fallback.
              controls.previousButtonPushed(controls.previousButton as Any)
              try await Task.sleep(for: .milliseconds(70))
              try await compositorScreenshot("player-transport-previous-transition.png")
              self.appDelegate.player.setAutoplayEnabled(false)
              self.appDelegate.player.setRepeatMode(.off)
              self.appDelegate.player.play(context: PlayContext(name: "Single song", playables: [nextSong]))
              try await Task.sleep(for: .milliseconds(700))
              self.appDelegate.player.seek(toSecond: 42)
              controls.nextButtonPushed(controls.nextButton as Any)
              try await Task.sleep(for: .milliseconds(70))
              try await compositorScreenshot("player-transport-next-transition.png")
              try await Task.sleep(for: .milliseconds(500))
              guard !self.appDelegate.player.isPlaying,
                    self.appDelegate.player.currentlyPlaying == nextSong,
                    self.appDelegate.player.prevQueueCount == 0 else {
                smokeLog("Single-song Next reset the queue or did not pause")
                return
              }
              self.appDelegate.player.setAutoplayEnabled(true)
              for _ in 0..<60 {
                if !self.appDelegate.player.autoplayQueue.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
              }
              guard let recommendation = self.appDelegate.player.autoplayQueue.first else {
                smokeLog("Autoplay did not prepare a local fallback after empty server recommendations")
                return
              }
              controls.displayPlaylistPressed()
              try await Task.sleep(for: .milliseconds(400))
              let autoplayPath = IndexPath(row: 0, section: PlayerSectionCategory.autoplay.rawValue)
              guard popup.tableView.numberOfRows(inSection: autoplayPath.section) > 0 else { return }
              popup.tableView.scrollToRow(at: autoplayPath, at: .middle, animated: false)
              popup.view.layoutIfNeeded()
              try await compositorScreenshot("player-autoplay-queue.png")
              guard let recommendationCell = popup.tableView.cellForRow(at: autoplayPath) as? PlayableTableCell else { return }
              recommendationCell.playThisSong()
              try await Task.sleep(for: .milliseconds(800))
              guard self.appDelegate.player.currentlyPlaying == recommendation,
                    self.appDelegate.player.isPlaying else {
                smokeLog("Choosing an Autoplay row did not start its recommendation")
                return
              }
              self.appDelegate.player.setAutoplayEnabled(false)
              guard self.appDelegate.player.autoplayQueue.isEmpty else { return }
              controls.displayPlaylistPressed()
              self.appDelegate.player.play(context: PlayContext(name: "Smoke", playables: [nextSong]))
              try await Task.sleep(for: .milliseconds(700))
              self.appDelegate.player.seek(toSecond: 42)
              smokeLog("Transport actions, single-song end pause and separate Autoplay recommendations with local fallback passed")
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
              try await compositorScreenshot("player-lyrics-controls.png")
              try await Task.sleep(for: .seconds(5))
              guard popup.areLyricsControlsHidden,
                    popup.largePlayerPlaceholderView.bounds.height > heightWithControls + 200 else {
                smokeLog("Lyrics controls did not hide and expand lyrics")
                return
              }
              popup.largeCurrentlyPlayingView?.refreshLyricsTime(time: CMTime(seconds: 42, preferredTimescale: 1000))
              guard activeLyricIsVisible() else { smokeLog("Immersive lyrics lost their highlight"); return }
              try await compositorScreenshot("player-lyrics-immersive.png")
              popup.restoreLyricsControls()
              try await Task.sleep(for: .seconds(1))
              guard !popup.areLyricsControlsHidden,
                    abs(popup.largePlayerPlaceholderView.bounds.height - heightWithControls) < 1 else { return }
              guard activeLyricIsVisible() else { smokeLog("Restoring controls lost the lyrics highlight"); return }
              smokeLog("Lyrics stayed highlighted across immersive layout changes")
              try await compositorScreenshot("player-lyrics-restored.png")
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
              // Keep real upcoming rows visible for queue layout review.
              self.appDelegate.player.appendContextQueue(playables: [song, nextSong, song])
              self.appDelegate.player.insertUserQueue(playables: [nextSong, song, nextSong])
              popup.controlView?.displayPlaylistPressed()
              guard try await compactHeaderStayedFixed(),
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .compact else {
                smokeLog("Lyrics to queue moved the fixed header")
                return
              }
              try await compositorScreenshot("player-queue-from-lyrics.png")
              // Exercise both sections and state updates, not just a single next row.
              for style in [UIUserInterfaceStyle.light, .dark] {
                popup.overrideUserInterfaceStyle = style
                for section in [PlayerSectionCategory.userQueue, .contextNext] {
                  popup.tableView.scrollToRow(at: IndexPath(row: 1, section: section.rawValue),
                                              at: .middle, animated: false)
                  popup.tableView.layoutIfNeeded()
                  let cells = popup.tableView.visibleCells.compactMap { $0 as? PlayableTableCell }
                  guard cells.count >= 2 else { return }
                  for cell in cells {
                    cell.setSelected(true, animated: false)
                    cell.updateConfiguration(using: cell.configurationState)
                    cell.refresh()
                    // UIKit may normalize a clear color to nil or a different
                    // color space. Compare effective opacity, not UIColor identity.
                    let backgrounds = [cell.backgroundColor, cell.contentView.backgroundColor,
                                       cell.backgroundConfiguration?.backgroundColor].compactMap { $0 }
                    guard backgrounds.allSatisfy({ $0.resolvedColor(with: cell.traitCollection).cgColor.alpha < 0.001 }) else {
                      smokeLog("Multi-song queue gained an opaque cell background: \(backgrounds)")
                      return
                    }
                    cell.setSelected(false, animated: false)
                  }
                }
              }
              popup.overrideUserInterfaceStyle = .dark
              popup.scrollToCurrentlyPlayingRow()
              popup.tableView.layoutIfNeeded()
              try await compositorScreenshot("player-queue-multiple.png")
              guard (largeView.artworkImage.gestureRecognizers ?? []).allSatisfy({ !($0 is UISwipeGestureRecognizer) }),
                    let controls = popup.controlView,
                    descendants(of: controls).compactMap({ $0 as? PlayerTrackSlider }).allSatisfy({
                      $0.trackRect(forBounds: $0.bounds).height >= 7
                    }) else {
                smokeLog("Full player retained artwork swiping or thin slider tracks")
                return
              }
              smokeLog("Multiple queue rows stayed clear across reuse, selection and appearance; artwork swiping disabled; 7pt tracks verified")
              func queueGlassIsAligned(in player: PopupPlayerVC) -> Bool {
                guard let background = player.queueModeBackgrounds,
                      background.superview === player.view, background.window != nil,
                      !background.isHidden, background.alpha > 0.99,
                      !background.isUserInteractionEnabled,
                      let header = player.contextNextQueueSectionHeader else { return false }
                let buttons = [header.shuffleButton, header.repeatButton, header.autoplayButton].compactMap { $0 }
                let materials = background.subviews.compactMap { $0 as? UIVisualEffectView }
                guard buttons.count == 3, materials.count == 3 else { return false }
                return zip(buttons, materials).allSatisfy { button, material in
                  let expected = button.convert(button.bounds, to: player.view)
                  let actual = material.convert(material.bounds, to: player.view)
                  return button.isDescendant(of: player.tableView) && material.effect is UIGlassEffect &&
                    !material.isHidden && abs(expected.minX - actual.minX) < 0.5 &&
                    abs(expected.minY - actual.minY) < 0.5 &&
                    abs(expected.width - actual.width) < 0.5 && abs(expected.height - actual.height) < 0.5
                }
              }
              if let header = popup.contextNextQueueSectionHeader {
                let originalOffset = popup.tableView.contentOffset
                let headerRect = popup.tableView.rectForHeader(inSection: PlayerSectionCategory.contextNext.rawValue)
                popup.tableView.scrollRectToVisible(headerRect, animated: false)
                popup.tableView.layoutIfNeeded()
                header.layoutIfNeeded()
                defer {
                  header.overrideUserInterfaceStyle = .unspecified
                  popup.tableView.setContentOffset(originalOffset, animated: false)
                  popup.tableView.layoutIfNeeded()
                }
                let buttons = [header.shuffleButton, header.repeatButton, header.autoplayButton].compactMap { $0 }
                for style in [UIUserInterfaceStyle.light, .dark] {
                  header.overrideUserInterfaceStyle = style
                  for button in buttons {
                    button.isHighlighted = true
                    button.setNeedsUpdateConfiguration()
                  }
                  try await Task.sleep(for: .milliseconds(60))
                  for button in buttons {
                    button.isHighlighted = false
                    button.setNeedsUpdateConfiguration()
                  }
                  header.refresh()
                  popup.view.layoutIfNeeded()
                  try await Task.sleep(for: .milliseconds(300))
                  for selected in [false, true] {
                    for button in buttons {
                      button.isSelected = selected
                      button.setNeedsUpdateConfiguration()
                    }
                    try await Task.sleep(for: .milliseconds(100))
                    header.layoutIfNeeded()
                    // Inspect the public, player-owned material views and real controls.
                    guard buttons.allSatisfy({ button in
                      let color = button.configuration?.imageColorTransformer?(.white)
                      return button.window != nil && !button.isHidden &&
                        button.configuration?.image != nil &&
                        (selected ? color == UIColor(white: 0.2, alpha: 1) : color == .white)
                    }), queueGlassIsAligned(in: popup) else {
                      smokeLog("Queue glass geometry, mode state or symbol contrast was lost after refresh")
                      return
                    }
                    try await compositorScreenshot("player-queue-glass-\(style.rawValue)-\(selected ? "selected" : "normal").png")
                  }
                  header.refresh()
                }
                // The same native controls must survive hiding and reopening the queue.
                popup.controlView?.displayPlaylistPressed()
                try await Task.sleep(for: .milliseconds(350))
                guard popup.tableView.alpha < 0.01 else {
                  smokeLog("Queue stayed visible after closing")
                  return
                }
                popup.controlView?.displayPlaylistPressed()
                try await Task.sleep(for: .milliseconds(350))
                popup.tableView.scrollRectToVisible(headerRect, animated: false)
                popup.view.layoutIfNeeded()
                header.layoutIfNeeded()
                guard popup.tableView.alpha > 0.99,
                      buttons.allSatisfy({ $0.window != nil && !$0.isHidden }),
                      queueGlassIsAligned(in: popup) else {
                  smokeLog("Reopened queue did not restore its controls")
                  return
                }
                try await compositorScreenshot("player-queue-glass-2-reopened.png")
                popup.beginInteractiveDismissal()
                try await Task.sleep(for: .milliseconds(80))
                popup.updateInteractiveDismissal(translation: 70)
                try await Task.sleep(for: .milliseconds(80))
                popup.endInteractiveDismissal(translation: 70, velocity: -150, cancelled: true)
                try await Task.sleep(for: .seconds(1))
                guard vc.presentedViewController === popup, popup.view.mask == nil,
                      queueGlassIsAligned(in: popup) else {
                  smokeLog("Cancelled queue dismissal did not restore native glass"); return
                }
                try await compositorScreenshot("player-queue-glass-2-cancelled.png")
                guard buttons.count == 3,
                      buttons.allSatisfy({ $0.bounds.width > 80 && $0.bounds.height >= 44 }),
                      header.queueNameLabel.frame.minY >= buttons[0].frame.maxY + 8,
                      popup.tableView.rowHeight == 56 else {
                  smokeLog("Queue mode controls or compact song rows do not match the player layout")
                  return
                }
              }
              smokeLog("Queue native glass geometry, symbol contrast, re-entry and cancelled dismissal passed in light and dark appearances")
              let queueOffset = popup.tableView.contentOffset
              let cardY = largeView.compactHeader.convert(largeView.compactHeader.bounds, to: popup.view).minY
              let controlsY = popup.controlPlaceholderView.frame.minY
              popup.tableView.setContentOffset(CGPoint(x: 0, y: queueOffset.y + 60), animated: false)
              popup.tableView.layoutIfNeeded()
              guard queueGlassIsAligned(in: popup) else {
                smokeLog("Queue glass did not track the scrolling controls"); return
              }
              try await compositorScreenshot("player-queue-glass-2-scrolled.png")
              popup.view.layoutIfNeeded()
              let scrolledY = largeView.compactHeader.convert(largeView.compactHeader.bounds, to: popup.view).minY
              guard abs(cardY - scrolledY - 60) < 1,
                    popup.controlPlaceholderView.frame.minY == controlsY else {
                smokeLog("Queue card did not scroll with songs, or transport moved")
                return
              }
              popup.tableView.setContentOffset(queueOffset, animated: false)
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              guard try await compactHeaderStayedFixed(),
                    largeView.isDisplayingLyrics,
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .large else {
                smokeLog("Queue to lyrics moved the fixed header")
                return
              }
              try await compositorScreenshot("player-lyrics-from-queue.png")
              popup.controlView?.displayPlaylistPressed()
              try await Task.sleep(for: .milliseconds(300))
              popup.controlView?.displayPlaylistPressed()
              try await Task.sleep(for: .milliseconds(500))
              guard !largeView.isDisplayingLyrics,
                    !self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed,
                    popup.controlView?.lyricsButton.isSelected == false,
                    self.appDelegate.storage.settings.user.playerDisplayStyle == .large else {
                smokeLog("Closing queue unexpectedly restored lyrics")
                return
              }
              try await compositorScreenshot("player-queue-closed-artwork.png")
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              try await Task.sleep(for: .milliseconds(500))
              smokeLog("Lyrics to queue to cover regression passed")

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
              smokeLog("Shared card survived switching; queue scrolling moved the card and retained fixed transport controls")
              func queueHeadersScrollWithSongs(in player: PopupPlayerVC) -> Bool {
                let headers: [(PlayerSectionCategory, UIView?)] = [
                  (.contextPrev, player.contextPrevQueueSectionHeader),
                  (.userQueue, player.userQueueSectionHeader),
                  (.contextNext, player.contextNextQueueSectionHeader),
                ]
                return headers.allSatisfy { section, view in
                  guard let view, view.window != nil else { return true }
                  let frame = view.convert(view.bounds, to: player.tableView)
                  let naturalFrame = player.tableView.rectForHeader(inSection: section.rawValue)
                  return view.superview === player.tableView && view.clipsToBounds &&
                    abs(frame.minY - naturalFrame.minY) < 0.5 &&
                    abs(frame.height - naturalFrame.height) < 0.5 &&
                    player.tableView.visibleCells.allSatisfy { cell in
                      let overlap = frame.intersection(cell.frame)
                      return overlap.isNull || overlap.height < 0.5
                    }
                }
              }
              // Use a history taller than the viewport and a plain table, whose
              // native section headers would otherwise float over the songs.
              self.appDelegate.player.appendContextQueue(playables: (0..<24).map { $0.isMultiple(of: 2) ? song : nextSong })
              self.appDelegate.player.play(playerIndex: PlayerIndex(queueType: .next, index: 12))
              try await Task.sleep(for: .milliseconds(500))
              popup.controlView?.displayPlaylistPressed()
              try await Task.sleep(for: .milliseconds(400))
              guard self.appDelegate.player.prevQueueCount > 0, popup.tableView.style == .plain,
                    CGFloat(self.appDelegate.player.prevQueueCount) * popup.tableView.rowHeight > popup.tableView.bounds.height else {
                smokeLog("History fixture did not exercise floating headers in a tall plain-table section"); return
              }
              popup.tableView.setContentOffset(CGPoint(x: 0, y: -popup.tableView.adjustedContentInset.top), animated: false)
              popup.view.layoutIfNeeded()
              try await compositorScreenshot("player-queue-history.png")
              let queueControlsY = popup.controlPlaceholderView.frame.minY
              let currentRect = popup.tableView.rectForRow(at: IndexPath(row: 0, section: PlayerSectionCategory.currentlyPlaying.rawValue))
              let modesRect = popup.tableView.rectForHeader(inSection: PlayerSectionCategory.contextNext.rawValue)
              let historyRect = popup.tableView.rectForHeader(inSection: PlayerSectionCategory.contextPrev.rawValue)
              let scrollCases: [(String, CGFloat)] = [
                ("history-near-top", 1),
                ("history-title-edge", historyRect.maxY - 1),
                ("history", 65),
                ("current", currentRect.minY + 60),
                ("modes", modesRect.minY + 30),
                ("beyond", modesRect.maxY + 40),
              ]
              for (name, offset) in scrollCases {
                popup.tableView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                popup.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                try await compositorScreenshot("player-queue-scroll-\(name).png")
                guard queueHeadersScrollWithSongs(in: popup) else {
                  smokeLog("Long queue \(name): visible heading entered a floating container or overlapped a song row")
                  return
                }
                let modesVisible = CGRect(x: modesRect.minX, y: modesRect.minY,
                                          width: modesRect.width, height: 44).intersects(popup.tableView.bounds)
                guard (!modesVisible || queueGlassIsAligned(in: popup)),
                      popup.controlPlaceholderView.frame.minY == queueControlsY else {
                  smokeLog("Long queue \(name): glass or transport detached while scrolling")
                  return
                }
              }
              popup.tableView.setContentOffset(CGPoint(x: 0, y: -popup.tableView.adjustedContentInset.top), animated: false)
              popup.view.layoutIfNeeded()
              smokeLog("Long history and upcoming queue scrolled without header/card overlap; native glass and transport stayed aligned")
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              try await Task.sleep(for: .milliseconds(250))
              popup.controlView?.displayPlaylistPressed()
              try await Task.sleep(for: .milliseconds(250))
              popup.dismiss(animated: false)
              try await Task.sleep(for: .milliseconds(200))
              miniPlayer.openPlayerView()
              for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if let current = vc.presentedViewController as? PopupPlayerVC,
                   current !== popup, !current.isBeingPresented, current.view.mask == nil { break }
              }
              guard let historyReopened = vc.presentedViewController as? PopupPlayerVC,
                    historyReopened !== popup, !historyReopened.isBeingPresented,
                    self.appDelegate.player.prevQueueCount > 0 else {
                smokeLog("Long history did not survive switching and reopening the player"); return
              }
              popup = historyReopened
              popup.tableView.setContentOffset(CGPoint(x: 0, y: historyRect.maxY - 1), animated: false)
              popup.view.layoutIfNeeded()
              try await Task.sleep(for: .milliseconds(200))
              guard queueHeadersScrollWithSongs(in: popup) else {
                smokeLog("Reopened history title floated over the first song"); return
              }
              try await compositorScreenshot("player-queue-history-reopened.png")
              smokeLog("Plain-table headings stayed in scroll content near the top and after lyrics switching and reopening")
              let playingBeforeClear = self.appDelegate.player.currentlyPlaying
              let upcomingBeforeClear = self.appDelegate.player.nextQueueCount
              popup.contextPrevQueueSectionHeader?.onClear?()
              guard self.appDelegate.player.prevQueueCount == 0,
                    self.appDelegate.player.currentlyPlaying == playingBeforeClear,
                    self.appDelegate.player.nextQueueCount == upcomingBeforeClear else {
                smokeLog("Clearing history changed playback or the upcoming queue"); return
              }
              popup.tableView.layoutIfNeeded()
              guard popup.contextPrevQueueSectionHeader?.window == nil else {
                smokeLog("Cleared history left its title over the current song"); return
              }
              popup.controlView?.displayPlaylistPressed()
              popup.controlView?.lyricsButton.sendActions(for: .touchUpInside)
              try await Task.sleep(for: .milliseconds(400))
              if let current = self.appDelegate.player.currentlyPlaying,
                 let cell = ViewCreator<PlayableTableCell>.createFromNib(withinFixedFrame: CGRect(x: 0, y: 0, width: 360, height: 64)) {
                cell.display(playable: current, playContextCb: { _ in PlayContext() }, rootView: vc)
                for height in [CGFloat(64), 80, 56] {
                  cell.frame.size.height = height
                  cell.setNeedsLayout()
                  cell.layoutIfNeeded()
                  guard let overlay = cell.entityImage.layer.sublayers?.first(where: { $0 is OverlayLayer }),
                        overlay.frame == cell.entityImage.bounds else {
                    smokeLog("Playing artwork overlay did not follow cell layout"); return
                  }
                }
                cell.prepareForReuse()
              }
              // Use the same animated dismissal and mini-player entry point as a user.
              // Bounded state checks report a failed transition instead of hanging on
              // a completion callback UIKit may discard during a modal handoff.
              popup.dismiss(animated: true)
              for _ in 0..<30 {
                if vc.presentedViewController == nil && popup.transitionCoordinator == nil { break }
                try await Task.sleep(for: .milliseconds(100))
              }
              guard vc.presentedViewController == nil else {
                smokeLog("Unexpected modal after closing lyrics: \(String(describing: vc.presentedViewController)); player presenting=\(popup.presentingViewController != nil)"); return
              }
              miniPlayer.openPlayerView()
              for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if let current = vc.presentedViewController as? PopupPlayerVC,
                   current !== popup, !current.isBeingPresented, current.view.mask == nil { break }
              }
              guard let reopened = vc.presentedViewController as? PopupPlayerVC,
                    reopened !== popup, !reopened.isBeingPresented, reopened.view.mask == nil else {
                smokeLog("Lyrics player did not finish reopening"); return
              }
              try await compositorScreenshot("player-lyrics-reopened.png")
              let lyricsButton = reopened.controlView?.lyricsButton
              if lyricsButton?.isSelected == true,
                 lyricsButton?.configuration?.baseForegroundColor == UIColor.black,
                 lyricsButton?.configuration?.imageColorTransformer?(.white) == UIColor.black,
                 lyricsButton?.tintColor == UIColor.black {
                smokeLog("Selected lyrics symbol preserved its contrast after reopening")
              } else {
                smokeLog("Lyrics symbol contrast failed: selected=\(String(describing: lyricsButton?.isSelected)), base=\(String(describing: lyricsButton?.configuration?.baseForegroundColor)), image=\(String(describing: lyricsButton?.configuration?.imageColorTransformer?(.white))), tint=\(String(describing: lyricsButton?.tintColor))")
                playerPolishChecksPassed = false
              }
              popup = reopened

              guard let lyricsView = descendants(of: popup.view).compactMap({ $0 as? LyricsView }).first else { return }
              popup.setLyricsControlsHidden(true, animated: false)
              lyricsView.handleDrag(velocity: CGPoint(x: 0, y: 300))
              guard !popup.areLyricsControlsHidden else { return }
              lyricsView.handleDrag(velocity: CGPoint(x: 0, y: -300))
              try await Task.sleep(for: .milliseconds(500))
              guard popup.areLyricsControlsHidden else { return }
              try await compositorScreenshot("player-lyrics-upward.png")
              popup.largeCurrentlyPlayingView?.lyricsArtworkPressed()
              try await Task.sleep(for: .seconds(1))
              guard popup.largeCurrentlyPlayingView?.isDisplayingLyrics == false,
                    !self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed,
                    !popup.areLyricsControlsHidden,
                    vc.presentedViewController === popup else {
                smokeLog("Lyrics artwork tap did not return to the cover and restore controls: lyrics=\(String(describing: popup.largeCurrentlyPlayingView?.isDisplayingLyrics)), setting=\(self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed), hidden=\(popup.areLyricsControlsHidden), presented=\(vc.presentedViewController === popup)")
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
              let returningCoverStartWidth = popup.transitionArtwork?.bounds.width ?? 72
              popup.endInteractiveDismissal(translation: 28, velocity: 900)
              var sampledClosingRebound = false
              var sampledReturningCover = false
              var previousReturningWidth = returningCoverStartWidth
              for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                guard popup.view.mask != nil,
                      let animatedFrame = renderedSurface(popup) else { continue }
                let destination = miniPlayer.glassContainer.bounds
                if animatedFrame.height < destination.height - 0.25 { sampledClosingRebound = true }
                if let cover = flyingCover() {
                  let frame = (cover.layer.presentation() ?? cover.layer).frame
                  if frame.width > previousReturningWidth + 0.5 ||
                        frame.width < miniPlayer.artworkImage.bounds.width - 0.5 {
                    smokeLog("Returning artwork bounced instead of travelling smoothly: \(frame)")
                    playerPolishChecksPassed = false
                  }
                  previousReturningWidth = frame.width
                  if frame.width > miniPlayer.artworkImage.bounds.width + 1,
                     frame.width < CurrentlyPlayingTableCell.artworkSide - 1 {
                    sampledReturningCover = true
                  }
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
              vc.dismiss(animated: false)
              self.appDelegate.storage.settings.user.playerDisplayStyle = .compact
              try await Task.sleep(for: .milliseconds(200))
              miniPlayer.openPlayerView()
              var resumedQueue: PopupPlayerVC?
              for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if let current = vc.presentedViewController as? PopupPlayerVC,
                   !current.isBeingPresented, current.view.mask == nil {
                  resumedQueue = current
                  break
                }
              }
              guard let resumedQueue else {
                smokeLog("Persisted queue did not reopen"); return
              }
              let modeRect = resumedQueue.tableView.rectForHeader(inSection: PlayerSectionCategory.contextNext.rawValue)
              resumedQueue.tableView.scrollRectToVisible(modeRect, animated: false)
              resumedQueue.view.layoutIfNeeded()
              try await Task.sleep(for: .milliseconds(300))
              guard queueGlassIsAligned(in: resumedQueue) else {
                smokeLog("Persisted queue did not restore native glass after full presentation"); return
              }
              guard resumedQueue.contextPrevQueueSectionHeader?.window == nil else {
                smokeLog("Reopened empty history left its title over the current song"); return
              }
              try await compositorScreenshot("player-queue-resumed.png")
              let songBeforeQueueClear = self.appDelegate.player.currentlyPlaying
              resumedQueue.clearUserQueue()
              try await Task.sleep(for: .milliseconds(500))
              resumedQueue.view.layoutIfNeeded()
              // UIKit can retain an empty header container during row updates.
              // Its title and action must be absent from the visible interface.
              try await compositorScreenshot("player-queue-empty.png")
              let emptyHeader = resumedQueue.userQueueSectionHeader
              let emptyHeaderHidden = emptyHeader?.window == nil ||
                (emptyHeader?.nameLabel.isHidden == true && emptyHeader?.rightButton.isHidden == true)
              let queueGlassAligned = queueGlassIsAligned(in: resumedQueue)
              let sameSongAfterClear = self.appDelegate.player.currentlyPlaying == songBeforeQueueClear
              guard self.appDelegate.player.userQueueCount == 0, sameSongAfterClear,
                    emptyHeaderHidden, queueGlassAligned else {
                smokeLog("Queue clear failed: remaining=\(self.appDelegate.player.userQueueCount), sameSong=\(sameSongAfterClear), headerHidden=\(emptyHeaderHidden), glassAligned=\(queueGlassAligned)")
                if let header = resumedQueue.contextNextQueueSectionHeader,
                   let background = resumedQueue.queueModeBackgrounds {
                  let controls = [header.shuffleButton, header.repeatButton, header.autoplayButton].compactMap { $0 }
                  smokeLog("Queue clear frames: controls=\(controls.map { $0.convert($0.bounds, to: resumedQueue.view) }), glass=\(background.subviews.map { $0.convert($0.bounds, to: resumedQueue.view) })")
                }
                return
              }
              resumedQueue.dismiss(animated: false)
              self.appDelegate.storage.settings.user.playerDisplayStyle = .large
              try await Task.sleep(for: .milliseconds(300))
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
                guard tabHost.selectedTab?.identifier == "Tabs.Search", searchFocused, dock.isHidden else {
                  smokeLog("Custom search navigation failed: controller=\(String(describing: search)), loaded=\(search?.isViewLoaded == true), active=\(search?.searchController.isActive == true), focused=\(searchFocused), dockHidden=\(dock.isHidden)")
                  return
                }
                let searchImage = UIGraphicsImageRenderer(bounds: tabHost.view.bounds).image { _ in
                  tabHost.view.drawHierarchy(in: tabHost.view.bounds, afterScreenUpdates: true)
                }
                try searchImage.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("player-search-keyboard.png"))
                // Close the integrated search session, as its Cancel control
                // does. Resigning only the text field leaves UISearchTab's
                // automatically activated search session running.
                search?.searchController.isActive = false
                search?.searchController.searchBar.searchTextField.resignFirstResponder()
                tabHost.view.window?.endEditing(true)
                for _ in 0..<30 {
                  try await Task.sleep(for: .milliseconds(100))
                  tabHost.view.layoutIfNeeded()
                  if !dock.isHidden { break }
                }
                guard !dock.isHidden,
                      search?.searchController.searchBar.searchTextField.isFirstResponder != true else {
                  smokeLog("Custom dock did not return after closing search: active=\(search?.searchController.isActive == true), focused=\(search?.searchController.searchBar.searchTextField.isFirstResponder == true), dockHidden=\(dock.isHidden), keyboardFrame=\(tabHost.view.keyboardLayoutGuide.layoutFrame)")
                  return
                }
                tabHost.selectedTab = tabHost.tabs.first(where: { $0.identifier == "Tabs.Home" })
                tabHost.view.layoutIfNeeded()
                guard tabHost.selectedTab?.identifier == "Tabs.Home", !dock.isCollapsed else { return }
                smokeLog("Native navigation, search keyboard hiding and restoration passed")
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
              if let tabHost = vc as? TabBarVC { try await ListeningStatisticsSmoke.run(on: tabHost) }
              guard playerPolishChecksPassed else { return }
              // UI gestures deliberately skip tracks. Prove a completed listen with
              // a dedicated short stream instead of counting seeks as listening.
              try await syncer.searchSongs(searchText: "scrobble-probe")
              guard let scrobbleSong = library.getSong(for: account, id: "song-scrobble") else {
                smokeLog("Short scrobble fixture was not synchronized"); return
              }
              try await syncer.sync(song: scrobbleSong)
              let playStarted = Date()
              self.appDelegate.player.clearUserQueue()
              self.appDelegate.player.setRepeatMode(.off)
              self.appDelegate.player.play(context: PlayContext(name: "Scrobble smoke", playables: [scrobbleSong]))
              var uploadedListen = false
              for _ in 0..<150 {
                if library.getScrobbleEntries(for: account).contains(where: {
                  $0.playable?.asSong == scrobbleSong && $0.isUploaded &&
                    ($0.date?.timeIntervalSince(playStarted) ?? -100) >= -1
                }) {
                  uploadedListen = true
                  break
                }
                try await Task.sleep(for: .milliseconds(100))
              }
              guard uploadedListen else {
                smokeLog("Real short-stream playback did not upload its timestamped listen"); return
              }
              smokeLog("Short audio played through the listening threshold and uploaded its timestamped history")
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
    #if DEBUG && targetEnvironment(simulator)
      if !resourceProfilePhase.isEmpty {
        let event: [String: Any] = ["phase": resourceProfilePhase,
                                    "state": "background", "playing": appDelegate.player.isPlaying]
        if let data = try? JSONSerialization.data(withJSONObject: event) {
          try? data.write(to: URL.documentsDirectory.appendingPathComponent("player-resource-background.json"), options: .atomic)
        }
      }
    #endif
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

#if DEBUG && targetEnvironment(simulator)
  extension SceneDelegate {
    // Test-only UI staging. Sampling runs outside the app so it does not add
    // an in-app polling timer or prevent a paused app from being suspended.
    @MainActor private func runPlayerResourceProfile(on host: UIViewController) async {
      let directory = URL.documentsDirectory
      func write(_ object: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
          .write(to: directory.appendingPathComponent(name), options: .atomic)
      }
      do {
        try await Task.sleep(for: .seconds(10))
        guard let accountInfo = appDelegate.storage.settings.accounts.active,
              let miniPlayer = (host as? MainSceneHostingViewController)?.miniPlayer else {
          throw NSError(domain: "ResourceProfile", code: 1)
        }
        let library = appDelegate.storage.main.library
        let account = library.getAccount(info: accountInfo)
        guard let song = library.getSong(for: account, id: "song-1") else {
          throw NSError(domain: "ResourceProfile", code: 2)
        }
        try await appDelegate.getMeta(accountInfo).librarySyncer.sync(song: song)
        appDelegate.storage.settings.user.playerDisplayStyle = .large
        appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
        appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
        appDelegate.player.isAutoCachePlayedItems = false
        let player = appDelegate.player
        player.setRepeatMode(.off)
        player.play(context: PlayContext(name: "Resource profile", playables: (0..<24).map { _ in song }))
        try await Task.sleep(for: .seconds(3))
        player.play(playerIndex: PlayerIndex(queueType: .next, index: 12))
        try await Task.sleep(for: .seconds(3))
        host.dismiss(animated: false)

        let phases = ["paused_cover", "playing_cover", "paused_queue", "playing_queue",
                      "playing_queue_scroll", "playing_lyrics", "paused_lyrics",
                      "playing_visualizer", "playing_transitions", "playing_background", "paused_background"]
        for (index, phase) in phases.enumerated() {
          resourceProfilePhase = phase
          if let popup = host.presentedViewController as? PopupPlayerVC { popup.dismiss(animated: false) }
          for _ in 0..<100 {
            if host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(100))
          }
          guard host.presentedViewController == nil else {
            throw NSError(domain: "ResourceProfile", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Previous player did not dismiss before \(phase)"])
          }
          let queue = phase.contains("queue")
          let lyrics = phase.contains("lyrics")
          let visualizer = phase.contains("visualizer")
          appDelegate.storage.settings.user.playerDisplayStyle = queue ? .compact : .large
          appDelegate.storage.settings.user.isPlayerLyricsDisplayed = lyrics
          appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = visualizer
          let playing = !phase.hasPrefix("paused")
          // A paused phase pauses the current item; do not also start an
          // asynchronous streaming seek while establishing its paused state.
          if playing { player.seek(toSecond: 10); player.play() } else { player.pause() }
          miniPlayer.openPlayerView()
          for _ in 0..<100 {
            if let popup = host.presentedViewController as? PopupPlayerVC,
               !popup.isBeingPresented, !popup.isBeingDismissed, popup.view.mask == nil { break }
            try await Task.sleep(for: .milliseconds(100))
          }
          try await Task.sleep(for: .seconds(2))
          guard let popup = host.presentedViewController as? PopupPlayerVC,
                !popup.isBeingPresented, player.isPlaying == playing else {
            let presented = host.presentedViewController
            throw NSError(domain: "ResourceProfile", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not stage \(phase): presented=\(String(describing: presented)), presenting=\(presented?.isBeingPresented ?? false), playing=\(player.isPlaying), expected=\(playing)"])
          }
          if visualizer { popup.largeCurrentlyPlayingView?.display(element: .visualizer, animated: false) }
          popup.view.layoutIfNeeded()
          guard popup.largeCurrentlyPlayingView?.isDisplayingLyrics == lyrics,
                !queue || (!popup.tableView.isHidden && popup.tableView.alpha > 0.99),
                player.audioAnalyzer.isActive == visualizer else {
            throw NSError(domain: "ResourceProfile", code: 5)
          }
          resourceProfilePhase = phase
          try write(["index": index, "phase": phase, "playing": player.isPlaying,
                     "background": phase.contains("background"), "pid": ProcessInfo.processInfo.processIdentifier,
                     "state": UIApplication.shared.applicationState.rawValue,
                     "queue": queue, "lyrics": lyrics, "visualizer": visualizer,
                     "audio_analyzer_active": player.audioAnalyzer.isActive], name: "player-resource-phase.json")
          if phase == "playing_queue_scroll" {
            let maximum = max(0, popup.tableView.contentSize.height - popup.tableView.bounds.height)
            for step in 0..<30 {
              popup.tableView.setContentOffset(CGPoint(x: 0, y: step.isMultiple(of: 2) ? 0 : maximum), animated: true)
              try await Task.sleep(for: .seconds(1))
            }
          } else if phase == "playing_transitions" {
            for _ in 0..<10 {
              (host.presentedViewController as? PopupPlayerVC)?.dismiss(animated: true)
              try await Task.sleep(for: .milliseconds(1500))
              miniPlayer.openPlayerView()
              try await Task.sleep(for: .milliseconds(1500))
            }
          } else {
            // Leave room for Settings' first launch and the background callback
            // before the external sampler's 20-second measurement window.
            try await Task.sleep(for: .seconds(phase.contains("background") ? 60 : 30))
          }
          guard player.isPlaying == playing else { throw NSError(domain: "ResourceProfile", code: 4) }
        }
        player.pause()
        resourceProfilePhase = ""
        try write(["completed": true, "phases": phases.count], name: "player-resource-ready.json")
      } catch {
        try? write(["error": String(describing: error), "phase": resourceProfilePhase], name: "player-resource-failed.json")
      }
    }
  }
#endif
