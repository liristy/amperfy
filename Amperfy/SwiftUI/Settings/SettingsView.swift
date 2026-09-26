//
//  SettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 14.09.22.
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
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  func screenLockPreventionOffPressed() {
    settings.screenLockPreventionPreference = .never
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionOnPressed() {
    settings.screenLockPreventionPreference = .always
    UIDevice.current.isBatteryMonitoringEnabled = false
    appDelegate.configureLockScreenPrevention()
  }

  func screenLockPreventionChargingPressed() {
    settings.screenLockPreventionPreference = .onlyIfCharging
    UIDevice.current.isBatteryMonitoringEnabled = true
    appDelegate.configureLockScreenPrevention()
  }

  func navigationLink(_ item: NavigationTarget) -> some View {
    NavigationLink(destination: AnyView(item.view())) {
      Text(item.displayName)
    }
  }

  var body: some View {
    let list =
      SettingsList {
        SettingsSection {
          SettingsRow(title: "Version".localized) {
            SecondaryText(AppDelegate.version)
          }
          SettingsRow(title: "Build Number".localized) {
            SecondaryText(AppDelegate.buildNumber)
          }
        }

        SettingsSection(
          content: {
            SettingsButtonRow(title: "Language".localized) {
              guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
              UIApplication.shared.open(url)
            }
          },
          footer: "Follow iPhone language; choose Chinese or English in system settings.".localized
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Offline Mode".localized, isOn: $settings.isOfflineMode)
          },
          footer:
          "Songs, podcasts, and artworks won’t download offline. Searches are limited to the device, and playlists won’t sync with the server.".localized
        )

        SettingsSection {
          SettingsRow(title: "Prevent Screen Lock".localized) {
            Menu(settings.screenLockPreventionPreference.description) {
              Button(
                ScreenLockPreventionPreference.never.description,
                action: screenLockPreventionOffPressed
              )
              Button(
                ScreenLockPreventionPreference.always.description,
                action: screenLockPreventionOnPressed
              )
              Button(
                ScreenLockPreventionPreference.onlyIfCharging.description,
                action: screenLockPreventionChargingPressed
              )
            }
          }
        }

        #if !targetEnvironment(macCatalyst) // ok
          SettingsSection {
            navigationLink(.account)
            navigationLink(.displayAndInteraction)
            navigationLink(.library)
            navigationLink(.player)
            navigationLink(.equalizer)
            navigationLink(.swipe)
            navigationLink(.artwork)
          }

          SettingsSection {
            navigationLink(.support)
            navigationLink(.license)
            navigationLink(.xcallback)

            #if DEBUG
              navigationLink(.developer)
            #endif
          }
        #endif
      }

    #if targetEnvironment(macCatalyst) // ok
      ZStack {
        list
      }
      .navigationTitle("General".localized)
      .navigationBarTitleDisplayMode(.inline)
    #else
      NavigationView {
        list
          .navigationTitle("Settings".localized)
      }
      .navigationViewStyle(.stack)
    #endif
  }
}

// MARK: - SettingsView_Previews

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}
