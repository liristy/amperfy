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
  // Cached palettes are applied while the destination is still offscreen. A
  // genuinely cold artwork download fades in only after navigation settles.
  func applyDetailBackgroundColor(_ color: UIColor) {
    guard view.backgroundColor != color else { return }
    guard view.window != nil else { view.backgroundColor = color; return }
    let update = { [weak self] in
      guard let self, UIApplication.shared.applicationState == .active else { return }
      UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.view.backgroundColor = color
      }
    }
    if let coordinator = transitionCoordinator, coordinator.isAnimated {
      coordinator.animate(alongsideTransition: nil) { context in
        if !context.isCancelled { update() }
      }
    } else { update() }
  }
}


// One owner updates native navigation and the floating dock in the same transition.
// Detail controllers must not restore shared bar properties after a pop completes.
final class MusicNavigationController: UINavigationController, UINavigationControllerDelegate {
  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    navigationBar.prefersLargeTitles = true
  }

  private func applyAppearance(for controller: UIViewController) {
    let artworkPage = controller is AlbumDetailVC || controller is PlaylistDetailVC ||
      controller is ArtistDetailVC || controller is ArtistRankingVC
    let style: UIUserInterfaceStyle = artworkPage ? .dark : .unspecified
    let tint: UIColor = artworkPage ? .white : appDelegate.storage.settings.accounts.activeSetting.read.themePreference.asColor
    if navigationBar.overrideUserInterfaceStyle != style { navigationBar.overrideUserInterfaceStyle = style }
    if navigationBar.tintColor != tint { navigationBar.tintColor = tint }
    if (artworkPage || controller is HomeVC || controller is LibraryVC), !navigationBar.prefersLargeTitles {
      navigationBar.prefersLargeTitles = true
    }
    if let host = tabBarController as? TabBarVC {
      host.reserveDockSpace(for: controller)
      if host.activeNavigationController === self { host.applyNavigationChrome(style: style) }
    }
  }

  func synchronizeAppearance() {
    if let controller = topViewController { applyAppearance(for: controller) }
  }

  func navigationController(_ navigationController: UINavigationController,
                            willShow controller: UIViewController, animated: Bool) {
    (tabBarController as? TabBarVC)?.reserveDockSpace(for: controller)
    guard animated, let coordinator = transitionCoordinator else {
      applyAppearance(for: controller)
      return
    }
    coordinator.animate(alongsideTransition: { [weak self] _ in
      self?.applyAppearance(for: controller)
    }, completion: { [weak self] context in
      if context.isCancelled, let original = context.viewController(forKey: .from) {
        self?.applyAppearance(for: original)
      }
    })
  }

  func navigationController(_ navigationController: UINavigationController,
                            didShow controller: UIViewController, animated: Bool) {
    // Also covers transitions without a coordinator and cancelled interactive pops.
    applyAppearance(for: controller)
  }
}
