//
//  PlayerSettingsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 15.09.22.
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

// MARK: - PlayerSettingsView

struct PlayerSettingsView: View {
  @EnvironmentObject
  private var settings: Settings

  private func updateBitrate(
    wifi: StreamingMaxBitratePreference? = nil,
    cellular: StreamingMaxBitratePreference? = nil
  ) {
    if let wifi = wifi {
      settings.streamingMaxBitrateWifiPreference = wifi
    }
    if let cellular = cellular {
      settings.streamingMaxBitrateCellularPreference = cellular
    }
    appDelegate.player.setStreamingMaxBitrates(
      to: StreamingMaxBitrates(
        wifi: settings.streamingMaxBitrateWifiPreference,
        cellular: settings.streamingMaxBitrateCellularPreference
      )
    )
  }

  private func updateFormatCell(_ format: StreamingFormatPreference) {
    settings.streamingFormatCellularPreference = format

    appDelegate.player.setStreamingTranscodings(to: StreamingTranscodings(
      wifi: settings.streamingFormatWifiPreference,
      cellular: settings.streamingFormatCellularPreference
    ))
  }

  private func updateFormatWifi(_ format: StreamingFormatPreference) {
    settings.streamingFormatWifiPreference = format

    appDelegate.player.setStreamingTranscodings(to: StreamingTranscodings(
      wifi: settings.streamingFormatWifiPreference,
      cellular: settings.streamingFormatCellularPreference
    ))
  }

  private func updateCacheFormat(_ format: CacheTranscodingFormatPreference) {
    settings.cacheTranscodingFormatPreference = format
  }

  var body: some View {
    ZStack {
      SettingsList {
        // ReplayGain Settings
        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Enable ReplayGain".localized,
              isOn: Binding(
                get: { settings.isReplayGainEnabled },
                set: { isEnabled in
                  settings.isReplayGainEnabled = isEnabled
                }
              )
            )
          },
          footer: "Automatically normalize track volume based on replay gain information for consistent loudness.".localized
        )

        // General Settings
        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Auto-cache played tracks and download upcoming ones".localized,
              isOn: $settings.isPlayerAutoCachePlayedItems
            )
          },
          footer: "Played tracks (songs and podcast episodes) are cached automatically. The next %ld tracks are downloaded in advance.".localizedFormat(PlayerDownloadPreparationHandler.preDownloadCount)
        )

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Song Playback Resume".localized,
              isOn: $settings.isPlayerSongPlaybackResumeEnabled
            )
          },
          footer: "Keeps track of song progress so playback continues from the previously saved position.".localized
        )

        SettingsSection(content: {
          SettingsCheckBoxRow(title: "Manual Playback".localized, isOn: $settings.isPlaybackStartOnlyOnPlay)
        }, footer: "Enable to start playback only when the Play button is pressed.".localized)

        SettingsSection(
          content: {
            SettingsCheckBoxRow(
              title: "Autoplay After End".localized,
              isOn: $settings.isAutoplayEnabled
            )
          },
          footer: "When the queue ends, automatically continue playback using Instant Mix to find similar songs.".localized
        )

        // Streaming Format Settings
        SettingsSection(
          content: {
            SettingsRow(title: "Cellular Streaming\nFormat (Transcoding)".localized) {
              Menu(settings.streamingFormatCellularPreference.description) {
                ForEach(StreamingFormatPreference.allCases, id: \.self) { format in
                  Button(format.description) {
                    updateFormatCell(format)
                  }
                }
              }
            }
          },
          footer: "Select a transcoding format for streaming while using Cellular. Transcoding is recommended for better compatibility.".localized
        )

        SettingsSection(
          content: {
            SettingsRow(title: "Cellular Streaming\nBitrate Limit".localized) {
              Menu(settings.streamingMaxBitrateCellularPreference.description) {
                ForEach(StreamingMaxBitratePreference.allCases, id: \.self) { bitrate in
                  Button(bitrate.description) {
                    updateBitrate(cellular: bitrate)
                  }
                }
              }
            }
          },
          footer: "Set the maximum streaming bitrate for Cellular.".localized
        )

        SettingsSection(
          content: {
            SettingsRow(title: "WiFi Streaming\nFormat (Transcoding)".localized) {
              Menu(settings.streamingFormatWifiPreference.description) {
                ForEach(StreamingFormatPreference.allCases, id: \.self) { format in
                  Button(format.description) {
                    updateFormatWifi(format)
                  }
                }
              }
            }
          },
          footer: "Select a transcoding format for streaming while on WiFi. Transcoding is recommended for better compatibility.".localized
        )
        // Streaming Bitrate Settings
        SettingsSection(
          content: {
            SettingsRow(title: "WiFi Streaming\nBitrate Limit".localized) {
              Menu(settings.streamingMaxBitrateWifiPreference.description) {
                ForEach(StreamingMaxBitratePreference.allCases, id: \.self) { bitrate in
                  Button(bitrate.description) {
                    updateBitrate(wifi: bitrate)
                  }
                }
              }
            }
          },
          footer: "Set the maximum streaming bitrate for WiFi.".localized
        )

        // Cache Format Settings
        SettingsSection(content: {
          SettingsRow(title: "Cache\nFormat (Transcoding)".localized) {
            Menu(settings.cacheTranscodingFormatPreference.description) {
              ForEach(CacheTranscodingFormatPreference.allCases, id: \.self) { format in
                Button(format.description) {
                  updateCacheFormat(format)
                }
              }
            }
          }
        }, footer: """
        Select a transcoding format for cached songs. Changes will not apply to already downloaded songs; clear cache and redownload if needed.
        \(
          appDelegate.storage.settings.accounts.getSetting(settings.activeAccountInfo).read
            .loginCredentials?.backendApi
            .asServerApiType == .ampache ? "" :
            """
            For 'raw', Amperfy uses the Subsonic API's 'download' action, which skips transcoding. Other formats use the 'stream' action, which requires proper server configuration for transcoding.
            """
        )
        """)
      }
    }
    .navigationTitle("Player, Stream & Scrobble".localized)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      appDelegate.userStatistics.visited(.settingsPlayer)
    }
  }
}

// MARK: - PlayerSettingsView_Previews

struct PlayerSettingsView_Previews: PreviewProvider {
  @State
  static var settings = Settings()

  static var previews: some View {
    PlayerSettingsView().environmentObject(settings)
  }
}
