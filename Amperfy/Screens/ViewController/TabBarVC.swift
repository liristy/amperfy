//
//  TabBarVC.swift
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
import UIKit

// MARK: - TabBarVC

class TabBarVC: UITabBarController {
  private var libraryGroup: UITabGroup?
  private var searchTab: UISearchTab?
  private(set) weak var searchViewController: SearchVC?
  private var homeTab: UITab?
  private let account: Account

  init(account: Account) {
    self.account = account
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var welcomePopupPresenter = WelcomePopupPresenter()
  var miniPlayer: MiniPlayerView?
  private(set) var playerDock: FloatingPlayerDock?
  private weak var dockInsetController: UIViewController?
  private var originalDockInset: CGFloat = 0
  private weak var dockScrollView: UIScrollView?
  private var dockScrollDistance: CGFloat = 0
  private var lastDockPanTranslation: CGFloat = 0
  private var dockKeyboardVisible = false
  private var dockSelectionIdentifier: String?
  private lazy var dockScrollPan: UIPanGestureRecognizer = {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDockScroll(_:)))
    pan.cancelsTouchesInView = false
    pan.delegate = self
    return pan
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UISearchTab { _ in
      let search = AppStoryboard.Main.segueToSearch(account: self.account)
      self.searchViewController = search
      return UINavigationController(rootViewController: search)
    }
    searchTab!.automaticallyActivatesSearch = true

    homeTab = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.icon,
      identifier: "Tabs.Home"
    ) { _ in
      UINavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
    }
    fixTabs.append(homeTab!)

    var libraryTabs = [UITab]()
    let libraryTabsShown = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.inUse
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.image,
          identifier: "Tabs.Library.\(item.rawValue)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsShown)

    let libraryTabsHidden = appDelegate.storage.settings.accounts
      .getSetting(account.info).read
      .libraryDisplaySettings.notUsed
      .compactMap { item in
        let tab = UITab(
          title: item.displayName,
          image: item.image,
          identifier: "Tabs.Library.\(item.rawValue)"
        ) { tab in
          item.controller(account: self.account, settings: self.appDelegate.storage.settings)
        }
        tab.allowsHiding = true
        tab.isHiddenByDefault = true
        return tab
      }
    libraryTabs.append(contentsOf: libraryTabsHidden)

    libraryGroup = UITabGroup(
      title: "Library".localized,
      image: .musicLibrary,
      identifier: "Tabs.Library",
      children: libraryTabs
    ) { tab in
      AppStoryboard.Main.segueToLibrary(account: self.account)
    }
    libraryGroup!.managingNavigationController = UINavigationController()
    libraryGroup!.allowsReordering = true
    fixTabs.append(libraryGroup!)
    fixTabs.append(searchTab!)

    delegate = self
    tabs = fixTabs

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleLibraryItemsChanged(notification:)),
      name: .LibraryItemsChanged,
      object: nil
    )

    miniPlayer = MiniPlayerView(player: appDelegate.player)
    miniPlayer!.configureForiOS()
    heightConstraint = miniPlayer!.glassContainer.heightAnchor.constraint(equalToConstant: 56)
    miniPlayer!.tabAccessoryTraitChangeCB = { [weak self] in
      self?.configureTraitChangesForMiniPlayer()
    }
    configureTraitChangesForMiniPlayer()
    view.addGestureRecognizer(dockScrollPan)
    NotificationCenter.default.addObserver(self, selector: #selector(dockKeyboardChanged(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(dockKeyboardHidden(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.miniPlayer?
          .refreshForTraitChange(horizontalSizeClass: self.traitCollection.horizontalSizeClass)
        self.configureTraitChangesForMiniPlayer()
      }
    )

    if appDelegate.storage.settings.user.isOfflineMode {
      appDelegate.eventLogger.info(topic: "Reminder".localized, message: "Offline Mode is active.".localized)
    }
  }

  private func mainContent() -> UIView {
    // Attempt to find the main content view controller's view if the sidebar is visible.
    // Fallback to self.view.safeAreaLayoutGuide.leadingAnchor otherwise.
    if traitCollection.horizontalSizeClass == .regular, let selectedViewController {
      return selectedViewController.view
    }
    return view
  }

  private weak var miniPlayerLayoutGuideView: UIView?
  private weak var miniPlayerAccessoryHost: UIView?
  private var miniPlayerHorizontalConstraints = [NSLayoutConstraint]()
  private var compactWidthConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?

  func configureTraitChangesForMiniPlayer() {
    guard let miniPlayer else { return }
    let container = miniPlayer.glassContainer
    let regular = traitCollection.horizontalSizeClass == .regular
    if traitCollection.userInterfaceIdiom == .phone || !regular {
      configureFloatingPlayerDock(miniPlayer: miniPlayer)
      return
    }
    if let dock = playerDock {
      container.removeFromSuperview()
      dock.removeFromSuperview()
      playerDock = nil
      miniPlayer.setCompactPresentation(nil)
      updateDockContentInset(visible: false)
    }
    if isTabBarHidden { setTabBarHidden(false, animated: false) }
    if tabBarMinimizeBehavior != .onScrollDown { tabBarMinimizeBehavior = .onScrollDown }
    if bottomAccessory == nil {
      container.translatesAutoresizingMaskIntoConstraints = false
      container.effect = nil
      bottomAccessory = UITabAccessory(contentView: container)
      heightConstraint?.isActive = true
    }
    guard let host = container.superview else { return }
    let inline = container.traitCollection.tabAccessoryEnvironment == .inline
    let height: CGFloat = regular ? 60 : (inline ? 48 : 56)
    if heightConstraint?.constant != height { heightConstraint?.constant = height }

    // UIKit owns accessory placement and its scroll-to-inline transition.
    // Cache our sizing constraints; never force layout from a layout callback.
    if miniPlayerAccessoryHost !== host {
      compactWidthConstraint?.isActive = false
      compactWidthConstraint = container.widthAnchor.constraint(equalTo: host.widthAnchor)
      miniPlayerAccessoryHost = host
    }
    let content = mainContent()
    if regular && miniPlayerLayoutGuideView !== content {
      NSLayoutConstraint.deactivate(miniPlayerHorizontalConstraints)
      let width = container.widthAnchor.constraint(equalTo: content.safeAreaLayoutGuide.widthAnchor)
      width.priority = .defaultHigh
      miniPlayerHorizontalConstraints = [
        container.centerXAnchor.constraint(equalTo: content.safeAreaLayoutGuide.centerXAnchor),
        width,
        container.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
      ]
      miniPlayerLayoutGuideView = content
    }
    if regular {
      compactWidthConstraint?.isActive = false
      NSLayoutConstraint.activate(miniPlayerHorizontalConstraints)
    } else {
      NSLayoutConstraint.deactivate(miniPlayerHorizontalConstraints)
      compactWidthConstraint?.isActive = true
    }
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    configureTraitChangesForMiniPlayer()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard let dock = playerDock else { return }
    let margin: CGFloat = 20
    let availableWidth = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
    let dockWidth = min(600, availableWidth - margin * 2)
    dock.frame = CGRect(x: view.safeAreaInsets.left + (availableWidth - dockWidth) / 2,
      y: view.bounds.height - view.safeAreaInsets.bottom - 8 - FloatingPlayerDock.expandedHeight,
      width: dockWidth,
      height: FloatingPlayerDock.expandedHeight)
    view.bringSubviewToFront(dock)
    updateDockSelection()
    let top = (selectedViewController as? UINavigationController)?.topViewController
    dock.isHidden = dockKeyboardVisible || top?.hidesBottomBarWhenPushed == true
    updateDockContentInset(visible: !dock.isHidden)
  }

  private func configureFloatingPlayerDock(miniPlayer: MiniPlayerView) {
    if playerDock == nil {
      heightConstraint?.isActive = false
      compactWidthConstraint?.isActive = false
      NSLayoutConstraint.deactivate(miniPlayerHorizontalConstraints)
      miniPlayerAccessoryHost = nil
      miniPlayerLayoutGuideView = nil
      bottomAccessory = nil
      miniPlayer.glassContainer.removeFromSuperview()
      miniPlayer.glassContainer.translatesAutoresizingMaskIntoConstraints = true
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      miniPlayer.glassContainer.effect = glass
      let dock = FloatingPlayerDock(miniPlayer: miniPlayer)
      dock.onHome = { [weak self] in
        guard let self else { return }
        self.selectedTab = self.homeTab
        self.updateDockSelection()
      }
      dock.onLibrary = { [weak self] in
        guard let self else { return }
        self.selectedTab = self.libraryGroup
        self.updateDockSelection()
      }
      dock.onSearch = { [weak self] in
        guard let self else { return }
        self.selectedTab = self.searchTab
        self.updateDockSelection()
        self.searchViewController?.activateSearchBar()
      }
      view.addSubview(dock)
      playerDock = dock
      dockSelectionIdentifier = nil
    }
    if tabBarMinimizeBehavior != .never { tabBarMinimizeBehavior = .never }
    if !isTabBarHidden { setTabBarHidden(true, animated: false) }
  }

  private func updateDockSelection() {
    guard let dock = playerDock else { return }
    let identifier = selectedTab?.identifier ?? "Tabs.Home"
    let selection = selectedTab === searchTab ? 2 : (identifier.hasPrefix("Tabs.Library") ? 1 : 0)
    let theme = appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference.asColor
    dock.updateSelection(selection, tint: theme)
    if identifier != dockSelectionIdentifier {
      dockSelectionIdentifier = identifier
      dockScrollDistance = 0
      dock.setCollapsed(false, animated: false)
      updateDockContentInset(visible: !dockKeyboardVisible)
      view.setNeedsLayout()
    }
  }

  private func updateDockContentInset(visible: Bool) {
    if dockInsetController !== selectedViewController {
      if let previous = dockInsetController { previous.additionalSafeAreaInsets.bottom = originalDockInset }
      dockInsetController = selectedViewController
      originalDockInset = selectedViewController?.additionalSafeAreaInsets.bottom ?? 0
    }
    guard let controller = dockInsetController else { return }
    // Keep the scroll viewport stable during sinking; the final row remains reachable.
    let inset = originalDockInset + (visible && playerDock != nil ? FloatingPlayerDock.expandedHeight + 8 : 0)
    if controller.additionalSafeAreaInsets.bottom != inset { controller.additionalSafeAreaInsets.bottom = inset }
  }

  func updatePlayerDockForScroll(delta: CGFloat, atTop: Bool) {
    guard let dock = playerDock, !dock.isHidden else { return }
    if atTop {
      dockScrollDistance = 0
      dock.setCollapsed(false, animated: true)
      return
    }
    if delta * dockScrollDistance < 0 { dockScrollDistance = 0 }
    dockScrollDistance += delta
    if dockScrollDistance < -28 {
      dock.setCollapsed(true, animated: true)
      dockScrollDistance = 0
    } else if dockScrollDistance > 18 {
      dock.setCollapsed(false, animated: true)
      dockScrollDistance = 0
    }
  }

  @objc private func handleDockScroll(_ pan: UIPanGestureRecognizer) {
    guard let scroll = dockScrollView else { return }
    let translation = pan.translation(in: view).y
    switch pan.state {
    case .began: lastDockPanTranslation = 0; dockScrollDistance = 0
    case .changed:
      let atTop = scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 2
      updatePlayerDockForScroll(delta: translation - lastDockPanTranslation, atTop: atTop)
      lastDockPanTranslation = translation
    default: break
    }
  }

  @objc private func dockKeyboardChanged(_ notification: Notification) {
    guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
          let window = view.window else { return }
    let localFrame = view.convert(window.convert(frame, from: nil), from: window)
    dockKeyboardVisible = localFrame.intersects(view.bounds) && localFrame.minY < view.bounds.maxY - view.safeAreaInsets.bottom
    view.setNeedsLayout()
  }

  @objc private func dockKeyboardHidden(_ notification: Notification) {
    dockKeyboardVisible = false
    view.setNeedsLayout()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    refresh()
    selectedTab = homeTab
    welcomePopupPresenter.displayInfoPopupsIfNeeded()
  }

  @objc
  func handleLibraryItemsChanged(notification: Notification) {
    refresh()
  }

  func refresh() {
    guard let libraryGroup else { return }
    let config = appDelegate.storage.settings.accounts.getSetting(account.info).read
      .libraryDisplaySettings
    libraryGroup.displayOrderIdentifiers = config.inUse.compactMap { "Tabs.Library.\($0.rawValue)" }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if let _ = config.inUse.first(where: { $0 == item }) {
        tab.isHidden = false
      } else {
        tab.isHidden = true
      }
    }
  }

  public func push(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
    selectedTab = libraryGroup
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  func tabBarControllerDidEndEditing(_ tabBarController: UITabBarController) {
    var visibleItems = [LibraryDisplayType]()
    guard let libraryGroup else { return }
    for tab in libraryGroup.displayOrder {
      guard let item = LibraryDisplayType.createByDisplayName(name: tab.title) else { continue }
      if !tab.isHidden {
        visibleItems.append(item)
      }
    }
    appDelegate.storage.settings.accounts
      .updateSetting(account.info) { accountSettings in
        accountSettings.libraryDisplaySettings = LibraryDisplaySettings(inUse: visibleItems)
      }
    NotificationCenter.default.post(name: .LibraryItemsChanged, object: nil, userInfo: nil)
  }
}

extension TabBarVC: UIGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard gestureRecognizer === dockScrollPan, playerDock?.isHidden == false else { return false }
    dockScrollView = nil
    var current = touch.view
    while let candidate = current, candidate !== view {
      if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled,
         scroll.bounds.height > view.bounds.height * 0.35,
         scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1 {
        dockScrollView = scroll
        return true
      }
      current = candidate.superview
    }
    return false
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dockScrollPan else { return true }
    let velocity = dockScrollPan.velocity(in: view)
    return dockScrollView != nil && abs(velocity.y) > abs(velocity.x)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                         shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    gestureRecognizer === dockScrollPan || otherGestureRecognizer === dockScrollPan
  }
}

// The phone's navigation and player share one layout, without depending on
// UIKit's private tab accessory hierarchy or changing the player's own height.
@MainActor
final class FloatingPlayerDock: UIView {
  static let playerHeight: CGFloat = 56
  static let navigationHeight: CGFloat = 52
  static let gap: CGFloat = 12
  static let expandedHeight = playerHeight + gap + navigationHeight
  private(set) var isCollapsed = false
  let miniPlayer: MiniPlayerView
  let navigationGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  let searchGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
  private let homeButton = UIButton(type: .system)
  private let libraryButton = UIButton(type: .system)
  private let searchButton = UIButton(type: .system)
  private let compactNavigationButton = UIButton(type: .system)
  private var selection = -1
  private var theme: UIColor?
  var onHome: (() -> Void)?
  var onLibrary: (() -> Void)?
  var onSearch: (() -> Void)?

  init(miniPlayer: MiniPlayerView) {
    self.miniPlayer = miniPlayer
    super.init(frame: .zero)
    accessibilityIdentifier = "floating-player-dock"
    miniPlayer.setCompactPresentation(false)
    addSubview(navigationGlass)
    addSubview(searchGlass)
    addSubview(miniPlayer.glassContainer)
    for glass in [navigationGlass, searchGlass] {
      glass.cornerConfiguration = .capsule()
    }
    navigationGlass.contentView.addSubview(homeButton)
    navigationGlass.contentView.addSubview(libraryButton)
    navigationGlass.contentView.addSubview(compactNavigationButton)
    searchGlass.contentView.addSubview(searchButton)
    homeButton.accessibilityLabel = TabNavigatorItem.home.title
    libraryButton.accessibilityLabel = "Library".localized
    searchButton.accessibilityLabel = TabNavigatorItem.search.title
    compactNavigationButton.accessibilityLabel = "Show navigation".localized
    homeButton.addAction(UIAction { [weak self] _ in self?.onHome?() }, for: .touchUpInside)
    libraryButton.addAction(UIAction { [weak self] _ in self?.onLibrary?() }, for: .touchUpInside)
    searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
    compactNavigationButton.addAction(UIAction { [weak self] _ in self?.setCollapsed(false, animated: true) }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func updateSelection(_ selected: Int, tint: UIColor) {
    guard selected != selection || theme != tint else { return }
    selection = selected
    theme = tint
    let icons = [TabNavigatorItem.home.icon, UIImage.musicLibrary, TabNavigatorItem.search.icon]
    let titles = [TabNavigatorItem.home.title, "Library".localized, TabNavigatorItem.search.title]
    for (index, button) in [homeButton, libraryButton, searchButton].enumerated() {
      var config = UIButton.Configuration.plain()
      config.image = icons[index]
      config.preferredSymbolConfigurationForImage = .init(pointSize: index == 2 ? 23 : 21, weight: .medium)
      config.baseForegroundColor = selected == index ? tint : .label
      config.contentInsets = .zero
      if index != 2 {
        config.title = titles[index]
        config.imagePlacement = .top
        config.imagePadding = 1
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
          var outgoing = incoming
          outgoing.font = .systemFont(ofSize: 10, weight: .medium)
          return outgoing
        }
      }
      button.configuration = config
      button.accessibilityTraits = selected == index ? [.button, .selected] : .button
    }
    var compact = UIButton.Configuration.plain()
    compact.image = icons[selected]
    compact.preferredSymbolConfigurationForImage = .init(pointSize: 23, weight: .medium)
    compact.baseForegroundColor = tint
    compactNavigationButton.configuration = compact
  }

  func setCollapsed(_ collapsed: Bool, animated: Bool) {
    guard isCollapsed != collapsed else { return }
    layoutIfNeeded()
    isCollapsed = collapsed
    miniPlayer.setCompactPresentation(collapsed)
    setNeedsLayout()
    let changes = { self.layoutIfNeeded() }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.44, delay: 0, usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
    } else {
      UIView.performWithoutAnimation(changes)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = Self.navigationHeight
    let rowY = Self.playerHeight + Self.gap
    let navigationWidth = isCollapsed ? side : max(side, bounds.width - side - Self.gap)
    navigationGlass.frame = CGRect(x: 0, y: rowY, width: navigationWidth, height: side)
    searchGlass.frame = CGRect(x: bounds.width - side, y: rowY, width: side, height: side)
    miniPlayer.glassContainer.frame = isCollapsed ?
      CGRect(x: side + Self.gap, y: rowY + 2, width: max(0, bounds.width - (side + Self.gap) * 2), height: 48) :
      CGRect(x: 0, y: 0, width: bounds.width, height: Self.playerHeight)
    navigationGlass.layoutIfNeeded()
    searchGlass.layoutIfNeeded()
    miniPlayer.glassContainer.layoutIfNeeded()
    homeButton.frame = CGRect(x: 4, y: 0, width: max(0, navigationWidth / 2 - 4), height: side)
    libraryButton.frame = CGRect(x: navigationWidth / 2, y: 0, width: max(0, navigationWidth / 2 - 4), height: side)
    searchButton.frame = CGRect(x: 0, y: 0, width: side, height: side)
    compactNavigationButton.frame = CGRect(x: 0, y: 0, width: side, height: side)
    for button in [homeButton, libraryButton] {
      button.alpha = isCollapsed ? 0 : 1
      button.isUserInteractionEnabled = !isCollapsed
      button.accessibilityElementsHidden = isCollapsed
    }
    compactNavigationButton.alpha = isCollapsed ? 1 : 0
    compactNavigationButton.isUserInteractionEnabled = isCollapsed
    compactNavigationButton.accessibilityElementsHidden = !isCollapsed
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // Empty space above a sunken player and the 12pt gap remain scrollable.
    [miniPlayer.glassContainer, navigationGlass, searchGlass].contains {
      $0.point(inside: convert(point, to: $0), with: event)
    }
  }
}

// MARK: MainSceneHostingViewController

extension TabBarVC: MainSceneHostingViewController {
  public func pushNavLibrary(vc: UIViewController) {
    push(vc: vc)
  }

  public func pushLibraryCategory(vc: UIViewController) {
    guard let libraryGroup else { return }
    libraryGroup.managingNavigationController?.popToRootViewController(animated: false)
    push(vc: vc)
  }

  func pushTabCategory(tabCategory: TabNavigatorItem) {
    switch tabCategory {
    case .home:
      selectedTab = homeTab
    case .search:
      selectedTab = searchTab
    }
    configureTraitChangesForMiniPlayer()
  }

  func displaySearch() {
    guard let searchTab else { return }
    visualizePopupPlayer(direction: .close, animated: true) {
      self.selectedTab = searchTab
      searchTab.viewController?.navigationController?.popToRootViewController(animated: false)
      Task {
        try await Task.sleep(nanoseconds: 500_000_000)
        if let searchTabVC = searchTab.viewController?.navigationController?
          .topViewController as? SearchVC {
          searchTabVC.activateSearchBar()
        }
      }
    }
  }

  func getSafeAreaExtension() -> CGFloat {
    0.0
  }
}
