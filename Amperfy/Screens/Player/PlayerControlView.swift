//
//  PlayerControlView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import MediaPlayer
import UIKit

// MARK: - PlayerControlView

class PlayerControlView: UIView {
  static let frameHeight: CGFloat = 268
  static private let margin = UIEdgeInsets(
    top: 0,
    left: 0,
    bottom: 20,
    right: 0
  )

  private var player: PlayerFacade!
  private var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?
  private let volumeSlider = PlayerTrackSlider()
  private var audioRouteTask: Task<Void, Never>?
  private static let audioIconPreferencesKey = "player.audioOutputIcons"
  private static var bluetoothIconCache = [String: String]()
  private var displayedAudioOutput: AudioOutput?
  private(set) var audioOutputIconName = "airplay.audio"
  struct AudioOutput {
    let portType: AVAudioSession.Port
    let name: String
    let uid: String
    var isBluetooth: Bool {
      [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains(portType)
    }
  }
  #if targetEnvironment(macCatalyst) // ok
    var airplayVolume: MPVolumeView?
  #endif

  @IBOutlet
  weak var playButton: UIButton!
  @IBOutlet
  weak var previousButton: UIButton!
  @IBOutlet
  weak var nextButton: UIButton!
  @IBOutlet
  weak var skipBackwardButton: UIButton!
  @IBOutlet
  weak var skipForwardButton: UIButton!

  @IBOutlet
  weak var timeSlider: UISlider!
  @IBOutlet
  weak var elapsedTimeLabel: UILabel!
  @IBOutlet
  weak var remainingTimeLabel: UILabel!
  @IBOutlet
  weak var liveLabel: UILabel!
  @IBOutlet
  weak var audioInfoLabel: UILabel!
  @IBOutlet
  weak var playTypeIcon: UIImageView!

  @IBOutlet
  weak var optionsStackView: UIStackView!
  @IBOutlet
  weak var playerModeButton: UIButton!
  @IBOutlet
  weak var airplayButton: UIButton!
  @IBOutlet
  weak var displayPlaylistButton: UIButton!
  @IBOutlet
  weak var volumeButton: UIButton!
  @IBOutlet
  weak var lyricsButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    #if targetEnvironment(macCatalyst) // ok
      self.airplayVolume = MPVolumeView(frame: .zero)
      airplayVolume!.showsVolumeSlider = false
      airplayVolume!.isHidden = true
    #endif

    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
    self.player = appDelegate.player
    player.addNotifier(notifier: self)
    NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(audioRouteChanged(_:)),
      name: UIApplication.didBecomeActiveNotification, object: nil)

    #if targetEnvironment(macCatalyst) // ok
      addSubview(airplayVolume!)
    #endif
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView

    playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)
    configureIconControls()
    configureVolumeSlider()
    timeSlider.minimumTrackTintColor = .white.withAlphaComponent(0.8)
    timeSlider.maximumTrackTintColor = .white.withAlphaComponent(0.18)
    timeSlider.accessibilityLabel = "Playback position".localized
    for label in [elapsedTimeLabel, remainingTimeLabel, audioInfoLabel] {
      label?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label?.textColor = .white.withAlphaComponent(0.65)
    }
    airplayButton.accessibilityLabel = "AirPlay"
    displayPlaylistButton.accessibilityLabel = "Playing next".localized
    volumeButton.accessibilityLabel = "Volume options".localized
    lyricsButton.addTarget(self, action: #selector(lyricsPressed), for: .touchUpInside)
    lyricsButton.tintColor = .white
    displayPlaylistButton.tintColor = .white

    playButton.imageView?.tintColor = .label
    previousButton.tintColor = .label
    nextButton.tintColor = .label
    skipBackwardButton.tintColor = .label
    skipForwardButton.tintColor = .label
    airplayButton.tintColor = .label
    playerModeButton.tintColor = .label
    volumeButton.tintColor = .label
    refreshPlayer()

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.playerHandler?.refreshTimeInfo(
          timeSlider: self.timeSlider,
          elapsedTimeLabel: self.elapsedTimeLabel,
          remainingTimeLabel: self.remainingTimeLabel,
          audioInfoLabel: self.audioInfoLabel,
          playTypeIcon: self.playTypeIcon,
          liveLabel: self.liveLabel
        )
      }
    )
  }

  private func configureVolumeSlider() {
    volumeSlider.translatesAutoresizingMaskIntoConstraints = false
    volumeSlider.minimumValue = 0
    volumeSlider.maximumValue = 1
    volumeSlider.value = player.volume
    volumeSlider.minimumTrackTintColor = .white.withAlphaComponent(0.7)
    volumeSlider.maximumTrackTintColor = .white.withAlphaComponent(0.18)
    volumeSlider.preferredBehavioralStyle = .pad
    volumeSlider.sliderStyle = .thumbless
    volumeSlider.accessibilityLabel = "Volume".localized
    volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
    addSubview(volumeSlider)

    let quietSpeaker = UIImageView(image: UIImage(systemName: "speaker.fill"))
    quietSpeaker.translatesAutoresizingMaskIntoConstraints = false
    quietSpeaker.contentMode = .scaleAspectFit
    quietSpeaker.tintColor = .white.withAlphaComponent(0.5)
    addSubview(quietSpeaker)
    NSLayoutConstraint.activate([
      quietSpeaker.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      quietSpeaker.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
      quietSpeaker.widthAnchor.constraint(equalToConstant: 16),
      quietSpeaker.heightAnchor.constraint(equalToConstant: 16),
      volumeSlider.leadingAnchor.constraint(equalTo: quietSpeaker.trailingAnchor, constant: 12),
      volumeSlider.trailingAnchor.constraint(equalTo: volumeButton.leadingAnchor, constant: -4),
      volumeSlider.centerYAnchor.constraint(equalTo: volumeButton.centerYAnchor),
      volumeSlider.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  private func configureIconControls() {
    // Keep the player controls as bare icons with their existing touch targets.
    for button in [playButton, previousButton, nextButton, skipBackwardButton,
                   skipForwardButton, airplayButton, playerModeButton, volumeButton] {
      guard let button else { continue }
      var configuration = UIButton.Configuration.player(isSelected: false)
      configuration.image = button.image(for: .normal)
      button.backgroundColor = .clear
      button.clipsToBounds = false
      button.configuration = configuration
    }
    refreshAudioOutputButton()
  }

  // The route name cannot identify a generation reliably. Plain "AirPods"
  // uses the modern 3/4 silhouette; a per-device choice can correct renamed
  // devices and older models without claiming to detect their hardware.
  static func audioOutputSymbol(portType: AVAudioSession.Port, portName: String,
                                preferredSymbol: String? = nil) -> String {
    switch portType {
    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
      if let preferredSymbol,
         ["airpods", "airpods.gen3", "airpodspro", "airpodsmax", "headphones"].contains(preferredSymbol) {
        return preferredSymbol
      }
      let name = portName.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        .filter { $0.isLetter || $0.isNumber }
        .lowercased()
      if name.contains("airpodsmax") { return "airpodsmax" }
      if name.contains("airpodspro") { return "airpodspro" }
      if name.contains("airpods1") || name.contains("airpods2") { return "airpods" }
      if name.contains("airpods") { return "airpods.gen3" }
      return "airplay.audio"
    case .headphones: return "headphones"
    case .carAudio: return "car.fill"
    default: return "airplay.audio"
    }
  }

  @objc nonisolated private func audioRouteChanged(_ notification: Notification) {
    Task { @MainActor [weak self] in self?.scheduleAudioOutputRefresh() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { scheduleAudioOutputRefresh() }
    else { audioRouteTask?.cancel() }
  }

  private func scheduleAudioOutputRefresh() {
    audioRouteTask?.cancel()
    audioRouteTask = Task { @MainActor [weak self] in
      // Profile/category changes can briefly report no output or the built-in
      // speaker. Coalesce them, then confirm the settled route once more.
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.refreshAudioOutputButton(settled: false)
      do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
      guard !Task.isCancelled else { return }
      self?.refreshAudioOutputButton()
    }
  }

  private func refreshAudioOutputButton(settled: Bool = true) {
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    let port = outputs.first { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver } ?? outputs.first
    renderAudioOutput(port.map { AudioOutput(portType: $0.portType, name: $0.portName, uid: $0.uid) },
                      settled: settled)
  }

  func renderAudioOutput(_ output: AudioOutput?, settled: Bool = true) {
    guard let airplayButton else { return }
    if !settled, output == nil || (displayedAudioOutput?.isBluetooth == true && output?.isBluetooth != true) {
      return
    }
    let preferences = UserDefaults.standard.dictionary(forKey: Self.audioIconPreferencesKey) as? [String: String] ?? [:]
    let preferred = output.flatMap { preferences[$0.uid] }
    let inferredSymbol = output.map { Self.audioOutputSymbol(portType: $0.portType, portName: $0.name) }
      ?? "airplay.audio"
    var symbol = inferredSymbol
    if let output, output.isBluetooth, !output.uid.isEmpty {
      if inferredSymbol != "airplay.audio" {
        if Self.bluetoothIconCache.count > 64 { Self.bluetoothIconCache.removeAll() }
        Self.bluetoothIconCache[output.uid] = inferredSymbol
      } else {
        // The same endpoint can temporarily have a generic name during a
        // profile change. Never borrow another device's model by name.
        symbol = Self.bluetoothIconCache[output.uid] ?? inferredSymbol
      }
      if let preferred {
        symbol = Self.audioOutputSymbol(portType: output.portType, portName: output.name, preferredSymbol: preferred)
      }
    }
    displayedAudioOutput = output
    audioOutputIconName = symbol
    var configuration = UIButton.Configuration.playerAccessory(isSelected: false)
    configuration.image = UIImage(systemName: symbol) ?? UIImage(systemName: "airplay.audio")
    airplayButton.configuration = configuration
    airplayButton.accessibilityValue = output?.name
    airplayButton.menu = nil
    airplayButton.accessibilityHint = nil
    guard let output, output.isBluetooth, !output.uid.isEmpty else { return }
    let choices: [(String, String?)] = [
      ("Automatic".localized, nil), ("AirPods 1 / 2", "airpods"),
      ("AirPods 3 / 4", "airpods.gen3"), ("AirPods Pro", "airpodspro"),
      ("AirPods Max", "airpodsmax"), ("Headphones".localized, "headphones"),
    ]
    airplayButton.menu = UIMenu(title: "Headphone Icon".localized, children: choices.map { title, value in
      UIAction(title: title, image: value.flatMap { UIImage(systemName: $0) },
               state: preferred == value ? .on : .off) { [weak self] _ in
        var saved = UserDefaults.standard.dictionary(forKey: Self.audioIconPreferencesKey) as? [String: String] ?? [:]
        saved[output.uid] = value
        UserDefaults.standard.set(saved, forKey: Self.audioIconPreferencesKey)
        self?.refreshAudioOutputButton()
      }
    })
    airplayButton.accessibilityHint = "Long press to choose headphone icon".localized
  }

  @objc
  private func volumeChanged() {
    player.volume = volumeSlider.value
  }

  @objc
  private func lyricsPressed() {
    let showLyrics = !appDelegate.storage.settings.user.isPlayerLyricsDisplayed ||
      appDelegate.storage.settings.user.playerDisplayStyle != .large
    appDelegate.storage.settings.user.isPlayerLyricsDisplayed = showLyrics
    appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
    if appDelegate.storage.settings.user.playerDisplayStyle != .large {
      displayPlaylistPressed()
    }
    rootView?.largeCurrentlyPlayingView?.display(element: showLyrics ? .lyrics : .artwork)
    refreshLyricsButton()
  }

  func refreshLyricsButton() {
    let selected = appDelegate.storage.settings.user.isPlayerLyricsDisplayed &&
      appDelegate.storage.settings.user.playerDisplayStyle == .large
    var configuration = UIButton.Configuration.playerAccessory(isSelected: selected)
    configuration.image = UIImage(systemName: "quote.bubble")?
      .withTintColor(selected ? .black : .white, renderingMode: .alwaysOriginal)
    lyricsButton.isSelected = selected
    lyricsButton.configuration = configuration
    lyricsButton.isEnabled = playerHandler?.isLyricsButtonAllowedToDisplay ?? false
    lyricsButton.accessibilityLabel = selected ? "Hide Lyrics".localized : "Show Lyrics".localized
  }

  @IBAction
  func playButtonPushed(_ sender: Any) {
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    playerHandler?.previousButtonPushed()
  }

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    playerHandler?.nextButtonPushed()
  }

  @IBAction
  func skipBackwardButtonPushed(_ sender: Any) {
    playerHandler?.skipBackwardButtonPushed()
  }

  @IBAction
  func skipForwardButtonPushed(_ sender: Any) {
    playerHandler?.skipForwardButtonPushed()
  }

  @IBAction
  func timeSliderChanged(_ sender: Any) {
    playerHandler?.timeSliderChanged(timeSlider: timeSlider)
  }

  @IBAction
  func timeSliderIsChanging(_ sender: Any) {
    playerHandler?.timeSliderIsChanging(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel
    )
  }

  @IBAction
  func airplayButtonPushed(_ sender: UIButton) {
    #if targetEnvironment(macCatalyst) // ok
      playerHandler?.airplayButtonPushed(
        rootView: self,
        airplayButton: airplayButton,
        airplayVolume: airplayVolume
      )
    #else
      playerHandler?.airplayButtonPushed(rootView: self, airplayButton: airplayButton)
    #endif
  }

  @IBAction
  func volumeButtonPressed(_ sender: Any) {
    showVolumeSliderMenu()
  }

  func showVolumeSliderMenu() {
    let popoverContentController = SliderMenuPopover()
    let sliderMenuView = popoverContentController.sliderMenuView
    sliderMenuView.frame = CGRect(x: 0, y: 0, width: 250, height: 50)

    sliderMenuView.slider.minimumValue = 0
    sliderMenuView.slider.maximumValue = 100
    sliderMenuView.slider.value = appDelegate.player.volume * 100

    sliderMenuView.sliderValueChangedCB = {
      self.appDelegate.player.volume = Float(sliderMenuView.slider.value) / 100.0
      self.volumeSlider.value = self.appDelegate.player.volume
    }

    popoverContentController.modalPresentationStyle = .popover
    popoverContentController.preferredContentSize = sliderMenuView.frame.size

    if let popoverPresentationController = popoverContentController.popoverPresentationController {
      popoverPresentationController.permittedArrowDirections = .down
      popoverPresentationController.delegate = popoverContentController
      popoverPresentationController.sourceView = volumeButton
      rootView?.present(
        popoverContentController,
        animated: true,
        completion: nil
      )
    }
  }

  @IBAction
  func displayPlaylistPressed() {
    rootView?.switchDisplayStyleOptionPersistent()
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
    refreshLyricsButton()
  }

  @IBAction
  func playerModeChangePressed(_ sender: Any) {
    switch player.playerMode {
    case .music:
      appDelegate.player.setPlayerMode(.podcast)
    case .podcast:
      appDelegate.player.setPlayerMode(.music)
    }
    refreshPlayerModeChangeButton()
  }

  func refreshView() {
    refreshPlayer()
  }

  func refreshPlayer() {
    // Playback and metadata changes must not overwrite a settled output icon
    // using a transient route snapshot. Route notifications own that update.
    if !volumeSlider.isTracking {
      volumeSlider.value = player.volume
    }
    refreshLyricsButton()
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
    playerHandler?.refreshPlayButton(playButton)
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
    playerHandler?.refreshPrevNextButtons(previousButton: previousButton, nextButton: nextButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
    refreshPlayerModeChangeButton()
  }

  func createPlaybackRateMenu() -> UIMenuElement {
    let playerPlaybackRate = player.playbackRate
    let availablePlaybackRates: [UIAction] = PlaybackRate.allCases.compactMap { playbackRate in
      UIAction(
        title: playbackRate.description,
        image: playbackRate == playerPlaybackRate ? .check : nil,
        handler: { _ in
          self.player.setPlaybackRate(playbackRate)
        }
      )
    }
    return UIMenu(
      title: "Playback Rate".localized,
      subtitle: playerPlaybackRate.description,
      image: .playbackRate,
      children: availablePlaybackRates
    )
  }

  func createVisualizerTypeMenu() -> UIMenuElement {
    let currentType = appDelegate.storage.settings.user.selectedVisualizerType
    let availableTypes: [UIAction] = VisualizerType.allCases.reversed()
      .compactMap { visualizerType in
        UIAction(
          title: visualizerType.displayName,
          image: UIImage(systemName: visualizerType.iconName),
          state: visualizerType == currentType ? .on : .off,
          handler: { _ in
            self.appDelegate.storage.settings.user.selectedVisualizerType = visualizerType
            self.rootView?.largeCurrentlyPlayingView?.showVisualizer()
          }
        )
      }
    return UIMenu(
      title: "Visualizer Style".localized,
      subtitle: currentType.displayName,
      image: .sparkles,
      children: availableTypes
    )
  }

  func createPlayerOptionsMenu() -> [UIMenuElement] {
    var menuActions = [UIMenuElement]()
    if player.currentlyPlaying != nil || player.prevQueueCount > 0 || player
      .userQueueCount > 0 || player.nextQueueCount > 0 {
      let clearPlayer = UIAction(title: "Clear Player".localized, image: .clear, handler: { _ in
        self.player.clearQueues()
      })
      menuActions.append(clearPlayer)
    }
    if player.userQueueCount > 0 {
      let clearUserQueue = UIAction(title: "Clear User Queue".localized, image: .playlistX, handler: { _ in
        self.rootView?.clearUserQueue()
      })
      menuActions.append(clearUserQueue)
    }

    menuActions.append(appDelegate.createSleepTimerMenu(refreshCB: nil))
    menuActions.append(createPlaybackRateMenu())

    if rootView?.largeCurrentlyPlayingView?.isLyricsButtonAllowedToDisplay ?? false {
      if !appDelegate.storage.settings.user.isPlayerLyricsDisplayed ||
        appDelegate.storage.settings.user.playerDisplayStyle != .large {
        let showLyricsAction = UIAction(title: "Show Lyrics".localized, image: .lyrics, handler: { _ in
          if !self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed {
            self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed.toggle()
            self.appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
            self.rootView?.largeCurrentlyPlayingView?.display(element: .lyrics)
          }
          if self.appDelegate.storage.settings.user.playerDisplayStyle != .large {
            self.displayPlaylistPressed()
          }
        })
        menuActions.append(showLyricsAction)
      } else {
        let hideLyricsAction = UIAction(title: "Hide Lyrics".localized, image: .lyrics, handler: { _ in
          self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed.toggle()
          self.rootView?.largeCurrentlyPlayingView?.display(element: .artwork)
        })
        menuActions.append(hideLyricsAction)
      }
    }

    if !appDelegate.storage.settings.user.isPlayerVisualizerDisplayed ||
      appDelegate.storage.settings.user.playerDisplayStyle != .large {
      let showVisualizerAction = UIAction(
        title: "Show Audio Visualizer".localized,
        image: .audioVisualizer,
        handler: { _ in
          if !self.appDelegate.storage.settings.user.isPlayerVisualizerDisplayed {
            self.appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = true
            self.appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
            self.rootView?.largeCurrentlyPlayingView?.display(element: .visualizer)
          }
          if self.appDelegate.storage.settings.user.playerDisplayStyle != .large {
            self.displayPlaylistPressed()
          }
        }
      )
      menuActions.append(showVisualizerAction)
    } else {
      let hideVisualizerAction = UIAction(
        title: "Hide Audio Visualizer".localized,
        image: .audioVisualizer,
        handler: { _ in
          self.appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
          self.rootView?.largeCurrentlyPlayingView?.display(element: .artwork)
        }
      )
      menuActions.append(hideVisualizerAction)

      // Add visualizer type selector submenu
      menuActions.append(createVisualizerTypeMenu())
    }

    switch player.playerMode {
    case .music:
      if player.currentlyPlaying != nil || player.prevQueueCount > 0 || player.nextQueueCount > 0,
         appDelegate.storage.settings.user.isOnlineMode {
        let addContextToPlaylist = UIAction(
          title: "Add Context Queue to Playlist".localized,
          image: .playlistPlus,
          handler: { _ in
            var itemsToAdd = self.player.getAllPrevQueueItems().filterSongs()
            if let currentlyPlaying = self.player.currentlyPlaying,
               let currentSong = currentlyPlaying.asSong {
              itemsToAdd.append(currentSong)
            }
            itemsToAdd.append(contentsOf: self.player.getAllNextQueueItems().filterSongs())
            // allow add to playlist only if all songs belong to the same account
            guard let firstItemAccount = itemsToAdd.first?.account,
                  itemsToAdd.count == itemsToAdd.filter({ $0.account == firstItemAccount }).count
            else { return }
            let selectPlaylistVC = AppStoryboard.Main
              .segueToPlaylistSelector(account: firstItemAccount, itemsToAdd: itemsToAdd)
            let selectPlaylistNav = UINavigationController(rootViewController: selectPlaylistVC)
            self.rootView?.present(selectPlaylistNav, animated: true, completion: nil)
          }
        )
        menuActions.append(addContextToPlaylist)
      }
    case .podcast: break
    }

    switch appDelegate.storage.settings.user.playerDisplayStyle {
    case .compact:
      let scrollToCurrentlyPlaying = UIAction(
        title: "Scroll to currently playing".localized,
        image: .squareArrow,
        handler: { _ in
          self.rootView?.scrollToCurrentlyPlayingRow()
        }
      )
      menuActions.append(scrollToCurrentlyPlaying)
    case .large: break
    }

    let playerInfo = UIAction(title: "Player Info".localized, image: .info, handler: { _ in
      guard let rootView = self.rootView else { return }
      let detailVC = PlainDetailsVC()
      detailVC.display(player: self.player, on: rootView)
      rootView.present(detailVC, animated: true)
    })
    menuActions.append(playerInfo)
    return menuActions
  }

  func refreshPlayerModeChangeButton() {
    playerModeButton.isHidden = appDelegate.player.podcastItemCount == 0 && appDelegate.player
      .playerMode != .podcast
    switch player.playerMode {
    case .music:
      playerModeButton.setImage(UIImage.musicalNotes, for: .normal)
      playerModeButton.configuration?.image = .musicalNotes
    case .podcast:
      playerModeButton.setImage(UIImage.podcast, for: .normal)
      playerModeButton.configuration?.image = .podcast
    }
    optionsStackView.layoutIfNeeded()
  }
}

// MARK: MusicPlayable

extension PlayerControlView: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {
    refreshPlayer()
  }

  func didPause() {
    refreshPlayer()
  }

  func didStopPlaying() {
    refreshPlayer()
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
  }

  func didElapsedTimeChange() {
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
  }

  func didPlaylistChange() {
    refreshPlayer()
  }

  func didArtworkChange() {}

  func didShuffleChange() {}

  func didRepeatChange() {}

  func didPlaybackRateChange() {}
}
