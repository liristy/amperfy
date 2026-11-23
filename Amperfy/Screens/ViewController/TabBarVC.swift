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
  private var searchTab: UITab?
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
  private let originalDockInsets = NSMapTable<UIViewController, NSNumber>.weakToStrongObjects()
  private weak var dockScrollView: UIScrollView?
  private var dockScrollDistance: CGFloat = 0
  private var lastDockPanTranslation: CGFloat = 0
  private var dockKeyboardVisible = false
  private var dockSelectionIdentifier: String?
  private var dockNavigationTop: CGFloat?
  private var dockLayoutSize: CGSize = .zero
  private var navigationGlass: UIVisualEffectView?
  private var originalTabAppearance: UITabBarAppearance?
  private var originalTabEdgeAppearance: UITabBarAppearance?
  private var originalNavigationAppearance: UITabBarAppearance?
  private var originalNavigationEdgeAppearance: UITabBarAppearance?
  private var navigationAppearanceIsArtwork: Bool?
  private var usesExplicitNavigationGlass: Bool {
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--smoke-chrome") {
        return arguments.contains("--smoke-chrome-legacy-clear") ||
          arguments.contains("--smoke-chrome-clear-outside")
      }
    #endif
    return false
  }
  private var placesNavigationGlassOutsideBar: Bool {
    #if DEBUG && targetEnvironment(simulator)
      return ProcessInfo.processInfo.arguments.contains("--smoke-chrome-clear-outside")
    #else
      return false
    #endif
  }
  private var dockGlassStyle: UIGlassEffect.Style {
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--smoke-chrome-baseline") || arguments.contains("--smoke-chrome-regular-mini") {
        return .regular
      }
    #endif
    // Match the native tab bar's regular glass. Clear glass makes the player
    // and collapsed buttons noticeably more transparent than the navigation.
    return .regular
  }
  private var automaticallyAdaptsNavigationGlass: Bool {
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--smoke-chrome") {
        return !arguments.contains("--smoke-chrome-baseline") && !arguments.contains("--smoke-chrome-forced")
      }
    #endif
    return true
  }
  private var usesImmediateNavigationTint: Bool {
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      if arguments.contains("--smoke-chrome") {
        return !arguments.contains("--smoke-chrome-baseline") && !arguments.contains("--smoke-chrome-no-tint")
      }
    #endif
    return true
  }
  #if DEBUG && targetEnvironment(simulator)
    private var glassReviewTabBar: UITabBar?
  #endif
  override var selectedTab: UITab? {
    didSet {
      if isViewLoaded { updateDockSelection() }
    }
  }
  private lazy var dockScrollPan: UIPanGestureRecognizer = {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDockScroll(_:)))
    pan.cancelsTouchesInView = false
    pan.delegate = self
    return pan
  }()

  override func viewDidLoad() {
    super.viewDidLoad()
    var fixTabs = [UITab]()

    searchTab = UITab(title: TabNavigatorItem.search.title,
      image: TabNavigatorItem.search.icon, identifier: "Tabs.Search") { _ in
      let search = AppStoryboard.Main.segueToSearch(account: self.account)
      self.searchViewController = search
      let navigation = MusicNavigationController(rootViewController: search)
      navigation.chromeHost = self
      return navigation
    }

    homeTab = UITab(
      title: TabNavigatorItem.home.title,
      image: TabNavigatorItem.home.icon,
      identifier: "Tabs.Home"
    ) { _ in
      let navigation = MusicNavigationController(
        rootViewController: TabNavigatorItem.home
          .getController(account: self.account)
      )
      navigation.chromeHost = self
      return navigation
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
    let libraryNavigation = MusicNavigationController()
    libraryNavigation.chromeHost = self
    libraryGroup!.managingNavigationController = libraryNavigation
    libraryGroup!.allowsReordering = true
    fixTabs.append(libraryGroup!)
    fixTabs.append(UITab(title: "Listening Statistics".localized,
      image: UIImage(systemName: "chart.bar.xaxis"), identifier: "Tabs.Listening") { _ in
      let navigation = MusicNavigationController(rootViewController: ListeningStatisticsVC(account: self.account))
      navigation.chromeHost = self
      return navigation
    })
    fixTabs.append(searchTab!)

    delegate = self
    tabs = fixTabs
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (host: TabBarVC, _: UITraitCollection) in
      guard host.automaticallyAdaptsNavigationGlass else { return }
      (host.activeNavigationController as? MusicNavigationController)?.synchronizeAppearance()
    }

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
    restoreNavigationAppearance()
    if let navigationGlass {
      navigationGlass.removeFromSuperview()
      self.navigationGlass = nil
      if let originalTabAppearance { tabBar.standardAppearance = originalTabAppearance }
      tabBar.scrollEdgeAppearance = originalTabEdgeAppearance
      originalTabAppearance = nil
      originalTabEdgeAppearance = nil
    }
    if isTabBarHidden { setTabBarHidden(false, animated: false) }
    tabBar.alpha = 1
    tabBar.isUserInteractionEnabled = true
    tabBar.accessibilityElementsHidden = false
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
    // Ask UIKit to distribute the native tabs across the available space.
    // Do not stretch the rendered bar or replace its interactive glass lens.
    if tabBar.itemPositioning != .fill { tabBar.itemPositioning = .fill }
    if tabBar.itemWidth != 0 { tabBar.itemWidth = 0 }
    if tabBar.itemSpacing != 0 { tabBar.itemSpacing = 0 }
    if !isTabBarHidden, tabBar.bounds.height > 0,
       dockNavigationTop == nil || dockLayoutSize != view.bounds.size {
      dockLayoutSize = view.bounds.size
      dockNavigationTop = tabBar.convert(tabBar.bounds, to: view).minY
    }
    let navigationTop = dockNavigationTop ??
      (view.bounds.height - view.safeAreaInsets.bottom - 8 - FloatingPlayerDock.navigationHeight)
    let dockFrame = CGRect(x: view.safeAreaInsets.left + (availableWidth - dockWidth) / 2,
      y: navigationTop - FloatingPlayerDock.gap - FloatingPlayerDock.playerHeight,
      width: dockWidth,
      height: FloatingPlayerDock.expandedHeight)
    if dock.frame != dockFrame { dock.frame = dockFrame }
    view.bringSubviewToFront(dock)
    updateDockSelection()
    let top = activeNavigationController?.topViewController
    dock.isHidden = dockKeyboardVisible || top?.hidesBottomBarWhenPushed == true
    updateDockContentInset(visible: !dock.isHidden)
    if let navigationGlass {
      let frame = CGRect(x: 20, y: 0, width: max(0, tabBar.bounds.width - 40),
                         height: min(FloatingPlayerDock.navigationHeight, tabBar.bounds.height))
      let glassParent: UIView = tabBar.superview ?? view
      let resolvedFrame = placesNavigationGlassOutsideBar ? tabBar.convert(frame, to: glassParent) : frame
      if navigationGlass.frame != resolvedFrame { navigationGlass.frame = resolvedFrame }
      navigationGlass.isHidden = dockKeyboardVisible || dock.isHidden || dock.isCollapsed
      if placesNavigationGlassOutsideBar {
        if tabBar.superview != nil { glassParent.insertSubview(navigationGlass, belowSubview: tabBar) }
      } else if tabBar.subviews.first !== navigationGlass { tabBar.sendSubviewToBack(navigationGlass) }
    }
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-standalone") {
        let review: UITabBar
        if let existing = glassReviewTabBar { review = existing }
        else {
          review = UITabBar()
          review.items = tabBar.items?.enumerated().map { index, item in
            UITabBarItem(title: item.title, image: item.image, tag: index)
          }
          review.itemPositioning = .fill
          view.addSubview(review)
          glassReviewTabBar = review
        }
        review.frame = tabBar.convert(tabBar.bounds, to: view)
        review.tintColor = tabBar.tintColor
        review.overrideUserInterfaceStyle = tabBar.overrideUserInterfaceStyle
        if let selected = tabBar.selectedItem,
           let index = tabBar.items?.firstIndex(of: selected), let items = review.items, index < items.count {
          review.selectedItem = items[index]
        }
        tabBar.alpha = 0
        view.bringSubviewToFront(review)
      }
    #endif
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
      let glass = UIGlassEffect(style: dockGlassStyle)
      glass.isInteractive = true
      if usesExplicitNavigationGlass {
        let playerGlass = UIGlassEffect(style: dockGlassStyle)
        playerGlass.isInteractive = true
        miniPlayer.glassContainer.effect = playerGlass
        originalTabAppearance = tabBar.standardAppearance
        originalTabEdgeAppearance = tabBar.scrollEdgeAppearance
        // Keep UIKit's tab controls and selection lens. A separate clear system
        // glass surface samples the moving content without regular glass's
        // delayed light/dark material adaptation during navigation.
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.backgroundImage = UIImage()
        tabBar.shadowImage = UIImage()
        tabBar.isTranslucent = true
        let effect = UIGlassEffect(style: dockGlassStyle)
        effect.isInteractive = true
        let background = UIVisualEffectView(effect: effect)
        background.cornerConfiguration = .capsule()
        background.isUserInteractionEnabled = false
        if placesNavigationGlassOutsideBar, let parent = tabBar.superview {
          parent.insertSubview(background, belowSubview: tabBar)
        }
        else { tabBar.insertSubview(background, at: 0) }
        navigationGlass = background
      } else { miniPlayer.glassContainer.effect = glass }
      let dock = FloatingPlayerDock(miniPlayer: miniPlayer,
        glassStyle: dockGlassStyle)
      dock.onSearch = { [weak self] in
        guard let self else { return }
        self.tabBar.alpha = 1
        self.tabBar.isUserInteractionEnabled = true
        self.selectedTab = self.searchTab
        self.updateDockSelection()
        self.searchViewController?.activateSearchBar()
      }
      dock.onCollapseChanged = { [weak self] animated in
        self?.updateNativeDockNavigation(animated: animated)
        self?.view.setNeedsLayout()
      }
      view.addSubview(dock)
      playerDock = dock
      dockSelectionIdentifier = nil
    }
    if tabBarMinimizeBehavior != .never { tabBarMinimizeBehavior = .never }
    updateNativeDockNavigation(animated: false)
  }

  private func updateNativeDockNavigation(animated: Bool) {
    guard let dock = playerDock else { return }
    let top = activeNavigationController?.topViewController
    // The native search field moves into the tab bar above the keyboard.
    // Hiding that bar would detach its first responder and dismiss the keyboard.
    let hiddenForNavigation = top?.hidesBottomBarWhenPushed == true
    if isTabBarHidden != hiddenForNavigation {
      setTabBarHidden(hiddenForNavigation, animated: animated)
    }
    // The real system tab bar owns the glass lens, touch tracking and tab
    // selection. During scroll collapse keep its layout reservation: changing
    // isTabBarHidden also changes the child's safe area and scroll offset, then
    // moves the dock again in the next layout pass. Only fade its surface.
    let visible = !dock.isCollapsed
    let alpha: CGFloat = visible ? 1 : 0
    if tabBar.alpha != alpha { tabBar.alpha = alpha }
    tabBar.isUserInteractionEnabled = visible
    tabBar.accessibilityElementsHidden = !visible
  }

  func applyNavigationChrome(style: UIUserInterfaceStyle) {
    // iOS 27 owns the floating material through its bar appearance object.
    // Overriding only the UITabBar view leaves that material in the app's style.
    var nativeStyle = style
    if automaticallyAdaptsNavigationGlass {
      if #available(iOS 27.0, *) {
        nativeStyle = .unspecified
      }
      #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-inherited") { nativeStyle = .unspecified }
      #endif
    }
    if tabBar.overrideUserInterfaceStyle != nativeStyle { tabBar.overrideUserInterfaceStyle = nativeStyle }
    if playerDock?.overrideUserInterfaceStyle != style { playerDock?.overrideUserInterfaceStyle = style }
    if #available(iOS 27.0, *), usesImmediateNavigationTint, playerDock != nil {
      applyImmediateNavigationAppearance(isArtwork: style == .dark)
    }
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-same-appearance"),
         tabBar.scrollEdgeAppearance == nil {
        // Diagnostic: keep UIKit's default material while removing the switch
        // between its standard and automatically transparent scroll-edge modes.
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
      }
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-host-style") ||
          ProcessInfo.processInfo.arguments.contains("--smoke-chrome-clear-host") {
        activeNavigationController?.view.overrideUserInterfaceStyle =
          ProcessInfo.processInfo.arguments.contains("--smoke-chrome-dark") ? .dark : .light
        view.overrideUserInterfaceStyle = style
      }
      glassReviewTabBar?.overrideUserInterfaceStyle = style
    #endif
  }

  @available(iOS 27.0, *)
  private func applyImmediateNavigationAppearance(isArtwork: Bool) {
    guard navigationAppearanceIsArtwork != isArtwork else { return }
    if originalNavigationAppearance == nil {
      originalNavigationAppearance = tabBar.standardAppearance.copy() as? UITabBarAppearance
      originalNavigationEdgeAppearance = tabBar.scrollEdgeAppearance?.copy() as? UITabBarAppearance
    }
    let wasArtwork = navigationAppearanceIsArtwork == true
    navigationAppearanceIsArtwork = isArtwork
    guard isArtwork || wasArtwork, let original = originalNavigationAppearance else { return }
    let standard = original.copy() as! UITabBarAppearance
    let edge = (originalNavigationEdgeAppearance ?? original).copy() as! UITabBarAppearance
    if isArtwork {
      // Set the system material's actual appearance, including its foreground
      // contrast. Background colors and per-item white overrides don't control
      // iOS 27's floating tab glass. Keep its native material and selection lens.
      for appearance in [standard, edge] {
        appearance.overrideUserInterfaceStyle = .dark
      }
    }
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tabBar.standardAppearance = standard
      tabBar.scrollEdgeAppearance = isArtwork ? edge : originalNavigationEdgeAppearance
      tabBar.setNeedsLayout()
      tabBar.layoutIfNeeded()
      CATransaction.commit()
    }
  }

  private func restoreNavigationAppearance() {
    if let original = originalNavigationAppearance, navigationAppearanceIsArtwork == true {
      UIView.performWithoutAnimation {
        tabBar.standardAppearance = original
        tabBar.scrollEdgeAppearance = originalNavigationEdgeAppearance
      }
    }
    originalNavigationAppearance = nil
    originalNavigationEdgeAppearance = nil
    navigationAppearanceIsArtwork = nil
  }

  private func updateDockSelection() {
    guard let dock = playerDock else { return }
    let identifier = selectedTab?.identifier ?? "Tabs.Home"
    let selection = selectedTab === searchTab ? 3 :
      (identifier == "Tabs.Listening" ? 2 : (identifier.hasPrefix("Tabs.Library") ? 1 : 0))
    let theme = appDelegate.storage.settings.accounts.getSetting(account.info).read.themePreference.asColor
    if tabBar.tintColor != theme { tabBar.tintColor = theme }
    dock.updateSelection(selection, tint: theme)
    if identifier != dockSelectionIdentifier {
      dockSelectionIdentifier = identifier
      (activeNavigationController as? MusicNavigationController)?.synchronizeAppearance()
      dockScrollDistance = 0
      dock.setCollapsed(false, animated: false)
      if selection == 3 {
        DispatchQueue.main.async { [weak self] in self?.searchViewController?.activateSearchBar() }
      }
      updateDockContentInset(visible: !dockKeyboardVisible)
      view.setNeedsLayout()
    }
  }

  var activeNavigationController: UINavigationController? {
    if selectedTab?.identifier.hasPrefix("Tabs.Library") == true {
      return libraryGroup?.managingNavigationController
    }
    return (selectedViewController as? UINavigationController) ?? selectedViewController?.navigationController
  }

  func reserveDockSpace(for controller: UIViewController, visible: Bool? = nil) {
    let original: CGFloat
    if let stored = originalDockInsets.object(forKey: controller) {
      original = CGFloat(stored.doubleValue)
    } else {
      original = controller.additionalSafeAreaInsets.bottom
      originalDockInsets.setObject(NSNumber(value: Double(original)), forKey: controller)
    }
    let showsDock = visible ?? (playerDock != nil && !dockKeyboardVisible && !controller.hidesBottomBarWhenPushed)
    // The native bar already reserves its own height. Reserve exactly one
    // player + gap on the leaf page before it appears, not on its navigation
    // container (UIKit can propagate that container inset only on a later layout).
    let inset = original + (showsDock ? FloatingPlayerDock.playerHeight + FloatingPlayerDock.gap : 0)
    if controller.additionalSafeAreaInsets.bottom != inset { controller.additionalSafeAreaInsets.bottom = inset }
  }

  private func updateDockContentInset(visible: Bool) {
    guard let controller = activeNavigationController?.topViewController ?? selectedViewController else { return }
    reserveDockSpace(for: controller, visible: visible)
  }

  func updatePlayerDockForScroll(delta: CGFloat, atTop: Bool) {
    // Resolve a pending tab change before the gesture changes collapse state.
    // Otherwise the layout requested by collapse can process that selection
    // later and immediately expand the dock again.
    updateDockSelection()
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
    if selectedTab == nil { selectedTab = homeTab }
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
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--smoke-chrome-baseline") {
        libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
        selectedTab = libraryGroup
        return
      }
    #endif
    // Select the navigation owner before UIKit starts the push. Reselecting
    // the same group afterwards can reset its glass during that transition.
    if selectedTab !== libraryGroup { selectedTab = libraryGroup }
    libraryGroup.managingNavigationController?.pushViewController(vc, animated: true)
  }
}

// MARK: UITabBarControllerDelegate

extension TabBarVC: UITabBarControllerDelegate {
  func tabBarController(_ tabBarController: UITabBarController,
                        didSelectTab selectedTab: UITab, previousTab: UITab?) {
    updateDockSelection()
  }

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

// Only the player floats above the native tab bar. When sunken, the player
// sits between two system glass buttons; no custom tab selection material exists.
@MainActor
final class FloatingPlayerDock: UIView {
  static let playerHeight: CGFloat = 56
  static let navigationHeight: CGFloat = 64
  private static let compactButtonSize: CGFloat = 48
  static let gap: CGFloat = 12
  static let expandedHeight = playerHeight + gap + navigationHeight
  private(set) var isCollapsed = false
  let miniPlayer: MiniPlayerView
  let navigationSlot = UIView()
  let searchSlot = UIView()
  private let searchButton = UIButton(type: .system)
  private let compactNavigationButton = UIButton(type: .system)
  private var selection = -1
  private var theme: UIColor?
  private let glassStyle: UIGlassEffect.Style
  var onCollapseChanged: ((Bool) -> Void)?
  var onSearch: (() -> Void)?

  init(miniPlayer: MiniPlayerView, glassStyle: UIGlassEffect.Style = .regular) {
    self.miniPlayer = miniPlayer
    self.glassStyle = glassStyle
    super.init(frame: .zero)
    accessibilityIdentifier = "floating-player-dock"
    miniPlayer.setCompactPresentation(false)
    addSubview(navigationSlot)
    addSubview(searchSlot)
    addSubview(miniPlayer.glassContainer)
    navigationSlot.addSubview(compactNavigationButton)
    searchSlot.addSubview(searchButton)
    navigationSlot.isHidden = true
    searchSlot.isHidden = true
    navigationSlot.alpha = 0
    searchSlot.alpha = 0
    searchButton.accessibilityLabel = TabNavigatorItem.search.title
    compactNavigationButton.accessibilityLabel = "Show navigation".localized
    searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
    compactNavigationButton.addAction(UIAction { [weak self] _ in self?.setCollapsed(false, animated: true) }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func updateSelection(_ selected: Int, tint: UIColor) {
    guard selected != selection || theme != tint else { return }
    selection = selected
    theme = tint
    let icons = [TabNavigatorItem.home.icon, UIImage.musicLibrary,
                 UIImage(systemName: "chart.bar.xaxis"), TabNavigatorItem.search.icon]
    var search = UIButton.Configuration.glass()
    let searchGlass = UIGlassEffect(style: glassStyle)
    searchGlass.isInteractive = true
    search.background.visualEffect = searchGlass
    search.cornerStyle = .capsule
    search.image = icons[3]
    search.preferredSymbolConfigurationForImage = .init(pointSize: 22, weight: .medium)
    search.baseForegroundColor = selected == 3 ? tint : .label
    searchButton.configuration = search
    var compact = UIButton.Configuration.glass()
    let compactGlass = UIGlassEffect(style: glassStyle)
    compactGlass.isInteractive = true
    compact.background.visualEffect = compactGlass
    compact.cornerStyle = .capsule
    compact.image = icons[selected]
    compact.preferredSymbolConfigurationForImage = .init(pointSize: 22, weight: .medium)
    compact.baseForegroundColor = tint
    compactNavigationButton.configuration = compact
  }

  func setCollapsed(_ collapsed: Bool, animated: Bool) {
    guard isCollapsed != collapsed else { return }
    layoutIfNeeded()
    isCollapsed = collapsed
    if collapsed {
      navigationSlot.isHidden = false
      searchSlot.isHidden = false
    }
    navigationSlot.isUserInteractionEnabled = collapsed
    searchSlot.isUserInteractionEnabled = collapsed
    let changes = {
      self.miniPlayer.setCompactPresentation(collapsed)
      self.setNeedsLayout()
      // The native bar, player and compact buttons share this transaction.
      // A separate UIKit hide/show animation would resize the scrolling page.
      self.onCollapseChanged?(false)
      self.layoutIfNeeded()
    }
    let finish = {
      self.navigationSlot.isHidden = !self.isCollapsed
      self.searchSlot.isHidden = !self.isCollapsed
    }
    if animated && !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.44, delay: 0, usingSpringWithDamping: 0.86,
        initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) { finished in
          if finished { finish() }
        }
    } else {
      UIView.performWithoutAnimation(changes)
      finish()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = Self.compactButtonSize
    let rowY = Self.playerHeight + Self.gap
    let buttonY = rowY + (Self.navigationHeight - side) / 2
    navigationSlot.frame = CGRect(x: 0, y: buttonY, width: side, height: side)
    searchSlot.frame = CGRect(x: bounds.width - side, y: buttonY, width: side, height: side)
    let playerFrame = isCollapsed ?
      CGRect(x: side + Self.gap, y: buttonY, width: max(0, bounds.width - (side + Self.gap) * 2), height: side) :
      CGRect(x: 0, y: 0, width: bounds.width, height: Self.playerHeight)
    // The player transition scales this live glass view. Assigning frame while
    // transformed changes its bounds and cancels the intended capsule shrink.
    miniPlayer.glassContainer.bounds = CGRect(origin: .zero, size: playerFrame.size)
    miniPlayer.glassContainer.center = CGPoint(x: playerFrame.midX, y: playerFrame.midY)
    miniPlayer.glassContainer.layoutIfNeeded()
    searchButton.frame = CGRect(x: 0, y: 0, width: side, height: side)
    compactNavigationButton.frame = CGRect(x: 0, y: 0, width: side, height: side)
    navigationSlot.alpha = isCollapsed ? 1 : 0
    searchSlot.alpha = isCollapsed ? 1 : 0
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    // In the expanded layout, every navigation touch passes through to the
    // system tab bar underneath, including its native press-and-drag gesture.
    [miniPlayer.glassContainer, navigationSlot, searchSlot].contains {
      !$0.isHidden && $0.isUserInteractionEnabled && $0.alpha > 0.01 &&
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
