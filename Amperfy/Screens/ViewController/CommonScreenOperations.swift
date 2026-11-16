//
//  CommonScreenOperations.swift
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
import Foundation
import UIKit

extension UIView {
  static let defaultMarginX: CGFloat = 25
  static let defaultMarginY: CGFloat = 11
  static let defaultMarginTopElement = UIEdgeInsets(
    top: 0.0,
    left: UIView.defaultMarginX,
    bottom: 0.0,
    right: UIView.defaultMarginX
  )
  static let defaultMarginMiddleElement = UIEdgeInsets(
    top: UIView.defaultMarginY,
    left: UIView.defaultMarginX,
    bottom: UIView.defaultMarginY,
    right: UIView.defaultMarginX
  )
  static let defaultMarginCellX: CGFloat = 16
  static let defaultMarginCellY: CGFloat = 9
  static let defaultMarginCell = UIEdgeInsets(
    top: UIView.defaultMarginCellY,
    left: UIView.defaultMarginCellX,
    bottom: UIView.defaultMarginCellY,
    right: UIView.defaultMarginCellX
  )
}

// MARK: - CommonScreenOperations

class CommonScreenOperations {
  static let tableSectionHeightLarge: CGFloat = 40
  static let tableSectionHeightFooter: CGFloat = 8
}

// MARK: - UIViewController

extension UIViewController {
  private func createUserButtonMenu() -> UIMenu {
    var accountActions = [UIMenuElement]()
    for accountInfo in appDelegate.storage.settings.accounts.allAccounts {
      let isActiveAccount = (accountInfo == appDelegate.storage.settings.accounts.active)
      let action = UIAction(
        title: appDelegate.storage.settings.accounts.getSetting(accountInfo).read
          .loginCredentials?
          .username ?? "Unknown".localized,
        subtitle: appDelegate.storage.settings.accounts.getSetting(accountInfo).read
          .loginCredentials?
          .displayServerUrl ?? "",
        image: .userCircle(withConfiguration: UIImage.SymbolConfiguration(
          pointSize: 30,
          weight: .regular
        )),
        attributes: isActiveAccount ? [UIMenuElement.Attributes.disabled] : [],
        state: isActiveAccount ? .on : .off,
        handler: { _ in
          self.appDelegate.switchAccount(accountInfo: accountInfo)
        }
      )
      accountActions.append(action)
    }

    #if targetEnvironment(macCatalyst)
      let addAccountImage = UIImage.plus
    #else
      let addAccountImage = UIImage.userCirclePlus
    #endif
    let openAddAccount = UIAction(
      title: "Add Account".localized,
      image: addAccountImage,
      handler: { _ in
        let loginVC = AppStoryboard.Main.segueToLogin()
        loginVC.modalPresentationStyle = .formSheet
        self.present(loginVC, animated: true)
      }
    )
    let openSettings = UIAction(
      title: "Settings".localized,
      image: .settings,
      handler: { _ in
        #if targetEnvironment(macCatalyst)
          self.appDelegate.showSettings(sender: "")
        #else
          let nav = AppStoryboard.Main.segueToSettings()
          nav.modalPresentationStyle = .formSheet
          self.present(nav, animated: true)
        #endif
      }
    )
    let settingsMenu = UIMenu(options: [.displayInline], children: [openAddAccount, openSettings])
    accountActions.append(settingsMenu)

    return UIMenu(
      title: "",
      image: nil,
      options: [.displayInline],
      children: accountActions
    )
  }

  public func setupUserNavButton(
    currentAccount: Account,
    userButton: inout UIButton?,
    userBarButtonItem: inout UIBarButtonItem?
  ) {
    let image = UIImage.userCircle(withConfiguration: UIImage.SymbolConfiguration(
      pointSize: 24,
      weight: .regular
    )).withTintColor(
      appDelegate.storage.settings.accounts.getSetting(currentAccount.info).read
        .themePreference.asColor,
      renderingMode: .alwaysTemplate
    )

    let button = UIButton(type: .system)
    button.setImage(image, for: .normal)
    button.tintColor = appDelegate.storage.settings.accounts.getSetting(currentAccount.info).read.themePreference.asColor
    button.layer.cornerRadius = 20
    button.clipsToBounds = true
    #if targetEnvironment(macCatalyst)
      button.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
    #else
      button.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
    #endif
    button.menu = createUserButtonMenu()
    button.showsMenuAsPrimaryAction = true
    userButton = button

    userBarButtonItem = UIBarButtonItem(customView: button)
    navigationItem.leftBarButtonItem = userBarButtonItem!
  }
}


extension UIViewController {
  // Prepare the backdrop before appearance. A palette arriving during a push
  // joins that transition; never queue a second recolor after it completes.
  func applyDetailBackgroundColor(_ color: UIColor) {
    guard view.backgroundColor != color else { return }
    guard view.window != nil else {
      UIView.performWithoutAnimation { view.backgroundColor = color }
      return
    }
    let update = { [weak self] in
      guard let self, UIApplication.shared.applicationState == .active else { return }
      UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.view.backgroundColor = color
      }
    }
    if let coordinator = transitionCoordinator, coordinator.isAnimated {
      let joined = coordinator.animate(alongsideTransition: { [weak self] _ in
        self?.view.backgroundColor = color
      }, completion: nil)
      if !joined {
        UIView.performWithoutAnimation { view.backgroundColor = color }
      }
    } else { update() }
  }
}


// One owner updates native navigation and the floating dock in the same transition.
// Detail controllers must not restore shared bar properties after a pop completes.
final class MusicNavigationController: UINavigationController, UINavigationControllerDelegate {
  weak var chromeHost: TabBarVC?

  private var recordsPreviousChromeBehavior: Bool {
    #if DEBUG && targetEnvironment(simulator)
      return ProcessInfo.processInfo.arguments.contains("--smoke-chrome-baseline")
    #else
      return false
    #endif
  }

  override func pushViewController(_ controller: UIViewController, animated: Bool) {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-slide") {
        controller.preferredTransition = nil
      }
    #endif
    prepareChromeBeforeNavigation(to: controller)
    super.pushViewController(controller, animated: animated)
  }

  override func popViewController(animated: Bool) -> UIViewController? {
    if viewControllers.count > 1 {
      prepareChromeBeforeNavigation(to: viewControllers[viewControllers.count - 2])
    }
    return super.popViewController(animated: animated)
  }

  override func popToViewController(_ controller: UIViewController, animated: Bool) -> [UIViewController]? {
    if topViewController !== controller, viewControllers.contains(where: { $0 === controller }) {
      prepareChromeBeforeNavigation(to: controller)
    }
    return super.popToViewController(controller, animated: animated)
  }

  override func popToRootViewController(animated: Bool) -> [UIViewController]? {
    if viewControllers.count > 1, let root = viewControllers.first {
      prepareChromeBeforeNavigation(to: root)
    }
    return super.popToRootViewController(animated: animated)
  }

  private func prepareChromeBeforeNavigation(to controller: UIViewController) {
    guard !recordsPreviousChromeBehavior else { return }
    // UIKit can capture its bar surfaces before willShow. Resolve the target
    // material while no navigation transition exists; never force a nested
    // navigation/tab-bar layout from inside UIKit's transition callback.
    guard let host = chromeHost ?? (tabBarController as? TabBarVC), host.isViewLoaded,
          host.activeNavigationController === self else { return }
    host.reserveDockSpace(for: controller)
    bindBottomContent(of: controller, to: host)
    let style: UIUserInterfaceStyle = usesArtworkChrome(for: controller) ? .dark : .unspecified
    UIView.performWithoutAnimation { host.applyNavigationChrome(style: style) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    navigationBar.prefersLargeTitles = true
  }

  private func usesArtworkChrome(for controller: UIViewController) -> Bool {
    controller is AlbumDetailVC || controller is PlaylistDetailVC ||
      controller is ArtistDetailVC || controller is ArtistRankingVC
  }

  private func bindBottomContent(of controller: UIViewController, to host: TabBarVC) {
    guard !recordsPreviousChromeBehavior else { return }
    // A UITabGroup owns a separate navigation container. Tell the shared bar
    // which leaf scroll view it should observe before UIKit captures the push,
    // rather than leaving it attached to the departing page until didShow.
    controller.loadViewIfNeeded()
    let scroll: UIScrollView?
    if let table = controller as? UITableViewController { scroll = table.tableView }
    else if let collection = controller as? UICollectionViewController { scroll = collection.collectionView }
    else { scroll = controller.view as? UIScrollView }
    // Keep the outgoing page's automatic edge treatment from becoming a
    // separate white backdrop while the incoming page moves below the glass.
    if let scroll, !scroll.bottomEdgeEffect.isHidden { scroll.bottomEdgeEffect.isHidden = true }
    for owner in [controller, self, host] as [UIViewController] {
      if owner.contentScrollView(for: .bottom) !== scroll {
        owner.setContentScrollView(scroll, for: .bottom)
      }
    }
  }

  private func applyAppearance(for controller: UIViewController) {
    let artworkPage = usesArtworkChrome(for: controller)
    let style: UIUserInterfaceStyle = artworkPage ? .dark : .unspecified
    let tint: UIColor = artworkPage ? .white : appDelegate.storage.settings.accounts.activeSetting.read.themePreference.asColor
    if navigationBar.overrideUserInterfaceStyle != style { navigationBar.overrideUserInterfaceStyle = style }
    if navigationBar.tintColor != tint { navigationBar.tintColor = tint }
    if (artworkPage || controller is HomeVC || controller is LibraryVC), !navigationBar.prefersLargeTitles {
      navigationBar.prefersLargeTitles = true
    }
    let host = (tabBarController as? TabBarVC) ?? (recordsPreviousChromeBehavior ? nil : chromeHost)
    if let host {
      host.reserveDockSpace(for: controller)
      if host.activeNavigationController === self {
        bindBottomContent(of: controller, to: host)
        host.applyNavigationChrome(style: style)
      }
    }
  }

  func synchronizeAppearance() {
    if let controller = topViewController { applyAppearance(for: controller) }
  }

  func navigationController(_ navigationController: UINavigationController,
                            willShow controller: UIViewController, animated: Bool) {
    (tabBarController as? TabBarVC)?.reserveDockSpace(for: controller)
    #if DEBUG && targetEnvironment(simulator)
      // Record the previous behavior in the same build for compositor comparison.
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-baseline"),
         animated, let coordinator = transitionCoordinator {
        coordinator.animate(alongsideTransition: { [weak self] _ in
          self?.applyAppearance(for: controller)
        }, completion: { [weak self] context in
          if context.isCancelled, let original = context.viewController(forKey: .from) {
            self?.applyAppearance(for: original)
          }
        })
        return
      }
    #endif
    // The bottom material is already prepared. Keep navigation-item colors in
    // UIKit's normal transition so Home's source/destination buttons still blend.
    guard animated, let coordinator = transitionCoordinator else {
      UIView.performWithoutAnimation { applyAppearance(for: controller) }
      return
    }
    let joined = coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.applyAppearance(for: controller)
    }, completion: { [weak self] context in
      if context.isCancelled, let original = context.viewController(forKey: .from) {
        UIView.performWithoutAnimation { self?.applyAppearance(for: original) }
      }
    })
    if !joined { UIView.performWithoutAnimation { applyAppearance(for: controller) } }
  }

  func navigationController(_ navigationController: UINavigationController,
                            didShow controller: UIViewController, animated: Bool) {
    // Also covers transitions without a coordinator and cancelled interactive pops.
    applyAppearance(for: controller)
  }
}

#if DEBUG && targetEnvironment(simulator)
  // Capture the real compositor separately from the full player suite. A small
  // window-level marker aligns navigation events with the external video; no
  // screenshots or rendering work run inside the animation's sampling loop.
  @MainActor
  enum NavigationGlassSmoke {
    private static let directory = URL.documentsDirectory

    private static func write(_ object: [String: Any], to name: String) throws {
      try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
      if !condition {
        throw NSError(domain: "NavigationGlassSmoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
      }
    }

    static func run(on controller: UIViewController) async {
      do { try await record(on: controller) }
      catch {
        try? write(["error": error.localizedDescription], to: "chrome-review-failed.json")
      }
    }

    private static func record(on controller: UIViewController) async throws {
      let app = UIApplication.shared.delegate as! AppDelegate
      guard let host = controller as? TabBarVC,
            let window = host.view.window,
            let info = app.storage.settings.accounts.active,
            let group = host.tabs.first(where: { $0.identifier == "Tabs.Library" }) as? UITabGroup,
            let nav = group.managingNavigationController else {
        throw NSError(domain: "NavigationGlassSmoke", code: 2)
      }
      let library = app.storage.main.library
      let account = library.getAccount(info: info)
      let meta = app.getMeta(info)
      try await meta.librarySyncer.syncDownPlaylistsWithoutSongs()
      guard let playlist = library.getPlaylist(for: account, id: "playlist-1") else {
        throw NSError(domain: "NavigationGlassSmoke", code: 3)
      }
      try await playlist.fetch(storage: app.storage, librarySyncer: meta.librarySyncer,
                               playableDownloadManager: meta.playableDownloadManager)
      if let song = library.getSong(for: account, id: "song-1") {
        try await meta.librarySyncer.sync(song: song)
        app.player.isAutoCachePlayedItems = false
        app.player.play(context: PlayContext(name: "Glass review", playables: [song]))
      }
      UserDefaults.standard.set([playlist.managedObject.objectID.uriRepresentation().absoluteString],
        forKey: "libraryPinnedPlaylists." + account.managedObject.objectID.uriRepresentation().absoluteString)
      let dark = ProcessInfo.processInfo.arguments.contains("--smoke-chrome-dark")
      host.overrideUserInterfaceStyle = dark ? .dark : .light
      host.dismiss(animated: false)
      host.selectedTab = group
      nav.popToRootViewController(animated: false)
      NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil)
      try await Task.sleep(for: .seconds(2))
      host.dismiss(animated: false)
      guard let source = nav.topViewController as? LibraryVC else {
        throw NSError(domain: "NavigationGlassSmoke", code: 4)
      }
      host.view.layoutIfNeeded()
      source.collectionView.layoutIfNeeded()
      try require(host.traitCollection.userInterfaceStyle == (dark ? .dark : .light),
                  "The source page did not use the requested light/dark appearance")
      let marker = UIView(frame: CGRect(x: window.bounds.midX - 5,
                                       y: window.safeAreaInsets.top + 4, width: 10, height: 10))
      marker.isUserInteractionEnabled = false
      marker.backgroundColor = .green
      window.addSubview(marker)
      defer { marker.removeFromSuperview() }
      var events = [[String: Any]]()
      defer { try? write(["events": events], to: "chrome-review-events.json") }
      func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
      func event(_ name: String) {
        let top = nav.topViewController
        var value: [String: Any] = ["name": name, "time": CACurrentMediaTime(),
          "bar_frame": rect(host.tabBar.convert(host.tabBar.bounds, to: window)),
          "marker_frame": rect(marker.frame),
          "animated": nav.transitionCoordinator?.isAnimated == true,
          "bar_style": host.tabBar.traitCollection.userInterfaceStyle.rawValue,
          "bar_override": host.tabBar.overrideUserInterfaceStyle.rawValue,
          "host_style": host.traitCollection.userInterfaceStyle.rawValue,
          "host_override": host.overrideUserInterfaceStyle.rawValue,
          "bar_tint_alpha": host.tabBar.standardAppearance.backgroundColor?.cgColor.alpha ?? 0,
          "page": String(describing: type(of: top)),
          "page_frame": rect(top?.view.layer.presentation()?.frame ?? top?.view.frame ?? .zero)]
        if name.hasSuffix(".source") || name.hasSuffix(".settled") {
          func describe(_ view: UIView, depth: Int) -> [String: Any] {
            var node: [String: Any] = ["type": String(describing: type(of: view)),
              "frame": rect(view.frame), "alpha": view.alpha, "hidden": view.isHidden]
            if let effect = view as? UIVisualEffectView { node["effect"] = String(describing: effect.effect) }
            if depth < 7 { node["children"] = view.subviews.map { describe($0, depth: depth + 1) } }
            return node
          }
          value["bar_tree"] = describe(host.tabBar, depth: 0)
        }
        events.append(value)
      }
      func settle(_ phase: String, endColor: UIColor) async throws {
        for _ in 0..<150 {
          try await Task.sleep(for: .milliseconds(16))
          event(phase + ".frame")
          if nav.transitionCoordinator == nil { break }
        }
        try require(nav.transitionCoordinator == nil, "Navigation did not settle for " + phase)
        UIView.performWithoutAnimation { marker.backgroundColor = endColor }
        event(phase + ".completed")
        try await Task.sleep(for: .seconds(1))
        event(phase + ".settled")
      }
      try write(["prepared": true], to: "chrome-review-prepared.json")
      for _ in 0..<600 {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("chrome-review-recording").path) { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      try require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("chrome-review-recording").path),
                  "External compositor recording did not start")
      event("pinned.source")
      try await Task.sleep(for: .milliseconds(500))
      guard let pinned = source.collectionView.visibleCells.first(where: {
        $0.accessibilityIdentifier == "library-pinned-playlist"
      }), let path = source.collectionView.indexPath(for: pinned) else {
        throw NSError(domain: "NavigationGlassSmoke", code: 5)
      }
      UIView.performWithoutAnimation { marker.backgroundColor = .red }
      event("pinned.push")
      source.collectionView(source.collectionView, didSelectItemAt: path)
      try require(nav.topViewController is PlaylistDetailVC, "Pinned playlist did not open its real detail page")
      try await settle("pinned.push", endColor: .blue)
      UIView.performWithoutAnimation { marker.backgroundColor = .yellow }
      event("pinned.pop")
      nav.popViewController(animated: true)
      try await settle("pinned.pop", endColor: .green)
      try require(nav.topViewController === source, "Pinned return did not restore the source page")
      source.collectionView.layoutIfNeeded()
      guard let category = source.collectionView.visibleCells.first(where: {
        $0.accessibilityIdentifier == "library-category-\(LibraryDisplayType.playlists.rawValue)"
      }), let categoryPath = source.collectionView.indexPath(for: category) else {
        throw NSError(domain: "NavigationGlassSmoke", code: 6)
      }
      source.collectionView(source.collectionView, didSelectItemAt: categoryPath)
      try await Task.sleep(for: .seconds(1))
      guard let list = nav.topViewController as? PlaylistsVC else {
        throw NSError(domain: "NavigationGlassSmoke", code: 7)
      }
      for _ in 0..<50 {
        if list.tableView.numberOfSections > 0, list.tableView.numberOfRows(inSection: 0) > 0 { break }
        try await Task.sleep(for: .milliseconds(100))
      }
      list.tableView.layoutIfNeeded()
      try require(list.tableView.numberOfSections > 0 && list.tableView.numberOfRows(inSection: 0) > 0,
                  "Playlist list did not contain the fixture")
      event("list.source")
      UIView.performWithoutAnimation { marker.backgroundColor = .red }
      event("list.push")
      list.tableView(list.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
      try require(nav.topViewController is PlaylistDetailVC, "Playlist row did not open its real detail page")
      try await settle("list.push", endColor: .blue)
      UIView.performWithoutAnimation { marker.backgroundColor = .yellow }
      event("list.pop")
      nav.popViewController(animated: true)
      try await settle("list.pop", endColor: .green)
      try require(nav.topViewController === list, "Playlist return did not restore its source row")
      try require(host.miniPlayer?.glassContainer.effect is UIGlassEffect, "System player material was replaced")
      // The route/state regression is independent of backdrop placement. Run it
      // once per runtime; the full UI suite also checks it in the production path.
      let audioCheck = ProcessInfo.processInfo.arguments.contains("--smoke-chrome-no-edge") && !dark
      if audioCheck {
        host.miniPlayer?.openPlayerView()
        for _ in 0..<80 {
          if let popup = host.presentedViewController as? PopupPlayerVC,
             !popup.isBeingPresented, popup.view.mask == nil { break }
          try await Task.sleep(for: .milliseconds(100))
        }
        guard let popup = host.presentedViewController as? PopupPlayerVC, let controls = popup.controlView else {
          throw NSError(domain: "NavigationGlassSmoke", code: 8)
        }
        try await controls.verifyAudioOutputStabilityForSmoke()
        popup.dismiss(animated: false)
      }
      try write(["appearance": dark ? "dark" : "light", "events": events,
                 "audio_output_checked": audioCheck,
                 "window": rect(window.bounds), "completed": true], to: "chrome-review-ready.json")
    }
  }
#endif
