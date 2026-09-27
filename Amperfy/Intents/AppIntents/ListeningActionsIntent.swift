//
//  ListeningActionsIntent.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 27.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import AppIntents
import Foundation

struct SetSleepTimerIntent: AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Stop Playback After a Delay"
  static let description = IntentDescription("Pause playback after the specified number of minutes. Set 0 to cancel the timer.")

  @Parameter(title: "Minutes", default: 30)
  var minutes: Int

  static var parameterSummary: some ParameterSummary {
    Summary("Stop playback after \(\.$minutes) minutes")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard (0...1440).contains(minutes) else { throw AmperfyAppIntentError.invalidSleepTimerDuration }
    appDelegate.activateSleepTimer(timeInterval: TimeInterval(minutes) * 60)
    let message = minutes == 0 ? "Sleep timer cancelled.".localized :
      String(format: "Playback will stop in %d minutes.".localized, minutes)
    return .result(dialog: IntentDialog(stringLiteral: message))
  }
}

struct ShuffleFavoritesIntent: AudioPlaybackIntent {
  static let title: LocalizedStringResource = "Shuffle Favorites"
  static let description = IntentDescription("Shuffle your favorite songs. In offline mode, only downloaded favorites are played.")

  @Parameter(title: "Account", description: "Account used to select songs from. If not provided the active account will be used.")
  var account: AccountAppEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Shuffle favorite songs") { \.$account }
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let libraryAccount = appDelegate.intentManager.getAccount(fromIntent: account) else {
      throw AmperfyAppIntentError.accountNotValid
    }
    let online = appDelegate.storage.settings.user.isOnlineMode
    let favorites = appDelegate.storage.main.library.getFavoriteSongs(for: libraryAccount)
      .filter { $0.isPlayableOniOS && (online || $0.isCached) }
    guard !favorites.isEmpty else { throw AmperfyAppIntentError.noPlayableFavorites }
    let songs = Array(favorites.shuffled().prefix(appDelegate.player.maxSongsToAddOnce))
    let context = PlayContext(name: "Favorites".localized, playables: songs)
    _ = appDelegate.intentManager.play(context: context, shuffleOption: true, repeatOption: .off)
    return .result(dialog: "Playing your favorite songs in random order.")
  }
}
