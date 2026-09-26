//
//  DisplaySettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 30.12.23.
//  Copyright (c) 2023 Maximilian Bauer. All rights reserved.
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

// MARK: - DisplaySettingsView

struct DisplaySettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  func setAppearanceMode(style: UIUserInterfaceStyle) {
    settings.appearanceMode = style
    appDelegate.setAppAppearanceMode(style: style)
  }

  var body: some View {
    ZStack {
      SettingsList {
        SettingsSection {
          SettingsRow(title: "Appearance".localized) {
            Menu(
              settings.appearanceMode == .unspecified ? "System".localized :
                (settings.appearanceMode == .light ? "Light".localized : "Dark".localized)
            ) {
              Button("System".localized) {
                setAppearanceMode(style: .unspecified)
              }
              Button("Light".localized) {
                setAppearanceMode(style: .light)
              }
              Button("Dark".localized) {
                setAppearanceMode(style: .dark)
              }
            }
          }
        }

        #if !targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(title: "Haptic Feedback".localized, isOn: $settings.isHapticsEnabled)
            },
            footer:
            "Certain interactions provide haptic feedback. Long pressing to display the details menu will always trigger haptic feedback.".localized
          )
        #endif

        #if targetEnvironment(macCatalyst)
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Mini Player Always on Top".localized,
                isOn: $settings.isMiniPlayerAlwaysOnTop
              )
            },
            footer:
            "Keep the mini player window floating above all other windows.".localized
          )
        #endif

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Music Player Skip Buttons".localized,
              isOn: $settings.isShowMusicPlayerSkipButtons
            )
          },
          footer:
          "Add skip forward and skip backward buttons to the music player, along with the previous/next buttons.".localized
        )

        if let activeAccountInfo = settings.activeAccountInfo,
           let credentials = appDelegate.storage.settings.accounts.getSetting(activeAccountInfo)
           .read.loginCredentials,
           credentials.backendApi.asServerApiType != .ampache {
          SettingsSection(
            content: {
              SettingsCheckBoxRow(
                title: "Lyrics Smooth Scrolling".localized,
                isOn: $settings.isLyricsSmoothScrolling
              )
            },
            footer:
            "Lyrics are smoothly scrolled to next line. Deactivating will result in jumping from line to line.".localized
          )
        }

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Detailed Information".localized,
              isOn: $settings.isShowDetailedInfo
            )
          },
          footer:
          "Display detailed information (bitrate, ID) and button \"Copy ID to Clipboard\"."
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Song Duration".localized, isOn: $settings.isShowSongDuration)
          },
          footer:
          "Display song duration in table rows.".localized
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Album Duration".localized, isOn: $settings.isShowAlbumDuration)
          },
          footer:
          "Display album duration in table rows.".localized
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(title: "Artist Duration".localized, isOn: $settings.isShowArtistDuration)
          },
          footer:
          "Display artist duration in table rows.".localized
        )


        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Disable Player Shuffle Button".localized,
              isOn: Binding<Bool>(
                get: { !settings.isPlayerShuffleButtonEnabled },
                set: {
                  settings.isPlayerShuffleButtonEnabled = !$0
                  UIMenuSystem.main.setNeedsRebuild()
                }
              )
            )
          },
          footer:
          "The player shuffle button is displayed but non-interactive.".localized
        )
      }
    }
    .navigationTitle("Display".localized)
    .navigationBarTitleDisplayMode(.inline)
  }
}

// MARK: - DisplaySettingsView_Previews

struct DisplaySettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    DisplaySettingsView().environmentObject(settings)
  }
}
