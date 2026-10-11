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

// MARK: - PlayerTransportButton

final class PlayerTransportButton: UIButton {
  private let pressDisc = UIView()
  private let symbolContainer = UIView()
  private let symbolView = UIImageView()
  private var symbolIdentifier: String?
  private var symbolAnimator: UIViewPropertyAnimator?
  private var symbolTransitionID = UUID()
  private var skipOverlay: UIView?
  private var skipAnimationID = UUID()
  private var skipAnimator: UIViewPropertyAnimator?
  private var pendingSkipDirection: CGFloat?
  private var currentSymbol: UIImage?

  override init(frame: CGRect) {
    super.init(frame: frame)
    prepareSymbolViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    prepareSymbolViews()
  }

  private func prepareSymbolViews() {
    pressDisc.backgroundColor = .white.withAlphaComponent(0.12)
    pressDisc.alpha = 0
    for view in [pressDisc, symbolContainer] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    symbolContainer.addSubview(symbolView)
    symbolView.contentMode = .center
    symbolView.tintColor = tintColor
    NotificationCenter.default.addObserver(self, selector: #selector(resetTransportMotion),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(resetTransportMotion),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    symbolView.tintColor = tintColor
    pressDisc.backgroundColor = tintColor.withAlphaComponent(0.12)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { resetTransportMotion() }
  }

  @objc private func resetTransportMotion() {
    cancelSkipMotion()
    symbolTransitionID = UUID()
    symbolAnimator?.stopAnimation(true)
    symbolAnimator = nil
    symbolView.image = currentSymbol
    symbolView.transform = .identity
    symbolView.alpha = 1
    isHighlighted = false
    pressDisc.layer.removeAllAnimations()
    symbolContainer.layer.removeAllAnimations()
    pressDisc.alpha = 0
    symbolContainer.transform = .identity
  }

  private func cancelSkipMotion() {
    let hadSkipOverlay = skipOverlay != nil
    skipAnimationID = UUID()
    pendingSkipDirection = nil
    skipAnimator?.stopAnimation(true)
    skipAnimator = nil
    skipOverlay?.removeFromSuperview()
    skipOverlay = nil
    if hadSkipOverlay { symbolView.alpha = 1 }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView?.isHidden = true
    let side = min(56, min(bounds.width, bounds.height))
    pressDisc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    pressDisc.center = CGPoint(x: bounds.midX, y: bounds.midY)
    pressDisc.layer.cornerRadius = side / 2
    // Keep the center and drawing canvas fixed while the glyph changes size.
    // Touch feedback belongs to the parent, independently of symbol replacement.
    symbolContainer.bounds = bounds
    symbolContainer.center = pressDisc.center
    symbolView.bounds = symbolContainer.bounds
    symbolView.center = CGPoint(x: symbolContainer.bounds.midX, y: symbolContainer.bounds.midY)
    skipOverlay?.center = CGPoint(x: symbolContainer.bounds.midX, y: symbolContainer.bounds.midY)
  }

  override var isHighlighted: Bool {
    didSet {
      guard oldValue != isHighlighted else { return }
      let pressed = isHighlighted
      UIView.animate(withDuration: pressed ? 0.09 : 0.18, delay: 0,
        usingSpringWithDamping: pressed ? 1 : 0.9, initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.pressDisc.alpha = pressed ? 1 : 0
        self.symbolContainer.transform = pressed && !UIAccessibility.isReduceMotionEnabled ?
          CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
      }
    }
  }

  func renderSymbol(_ image: UIImage, identifier: String) {
    guard symbolIdentifier != identifier || currentSymbol?.size != image.size else { return }
    cancelSkipMotion()
    currentSymbol = image
    let animated = symbolIdentifier != nil && window != nil && !UIAccessibility.isReduceMotionEnabled
    symbolIdentifier = identifier
    let transitionID = UUID()
    symbolTransitionID = transitionID
    // Finish at the rendered position so rapid taps don't restart from full size
    // or allow an older completion to install an outdated play/pause symbol.
    if let animator = symbolAnimator {
      animator.stopAnimation(false)
      animator.finishAnimation(at: .current)
      symbolAnimator = nil
    }
    guard animated else {
      symbolView.image = image
      symbolView.transform = .identity
      symbolView.alpha = 1
      setNeedsLayout()
      return
    }
    let shrink = UIViewPropertyAnimator(duration: 0.07, curve: .easeIn) {
      self.symbolView.transform = CGAffineTransform(scaleX: 0.15, y: 0.15)
      self.symbolView.alpha = 0
    }
    shrink.addCompletion { [weak self] _ in
      guard let self, symbolTransitionID == transitionID else { return }
      symbolView.image = image
      let expand = UIViewPropertyAnimator(duration: 0.2, dampingRatio: 0.9) {
        self.symbolView.transform = .identity
        self.symbolView.alpha = 1
      }
      expand.addCompletion { [weak self] _ in
        guard let self, symbolTransitionID == transitionID else { return }
        symbolAnimator = nil
      }
      symbolAnimator = expand
      expand.startAnimation()
    }
    symbolAnimator = shrink
    shrink.startAnimation()
  }

  func animateActivation(direction: CGFloat = 0) {
    // Release already fades the press feedback. Do not flash it again on tap.
    guard direction != 0, window != nil, !UIAccessibility.isReduceMotionEnabled,
          let image = symbolView.image else { return }
    if skipAnimator != nil {
      // Keep the visible flight continuous during rapid taps. Playback still
      // responds to every tap; at most one more visual cycle waits behind it.
      pendingSkipDirection = direction
      return
    }
    let animationID = UUID()
    skipAnimationID = animationID
    let overlay = UIView(frame: CGRect(origin: .zero, size: image.size))
    overlay.center = CGPoint(x: symbolContainer.bounds.midX, y: symbolContainer.bounds.midY)
    overlay.clipsToBounds = true
    overlay.isUserInteractionEnabled = false
    let slotWidth = image.size.width / 2
    var lanes: [UIView] = []
    for slot in (direction > 0 ? -1...1 : 0...2) {
      let lane = UIView(frame: CGRect(x: CGFloat(slot) * slotWidth, y: 0,
        width: slotWidth, height: image.size.height))
      lane.clipsToBounds = true
      // Slice the configured skip symbol itself. A separately sized play.fill
      // triangle changes its rounded corners, spacing and baseline mid-flight.
      let sourceHalf = direction > 0 ? (slot == 1 ? 1 : 0) : (slot == 0 ? 0 : 1)
      let glyph = UIImageView(image: image)
      glyph.tintColor = tintColor
      glyph.frame = CGRect(x: -CGFloat(sourceHalf) * slotWidth, y: 0,
        width: image.size.width, height: image.size.height)
      lane.addSubview(glyph)
      overlay.addSubview(lane)
      lanes.append(lane)
    }
    // Both the resting glyph and flying lanes share touch scale and center.
    symbolContainer.addSubview(overlay)
    skipOverlay = overlay
    symbolView.alpha = 0
    let timing = UICubicTimingParameters(controlPoint1: CGPoint(x: 0.22, y: 0),
      controlPoint2: CGPoint(x: 0.25, y: 1))
    let animator = UIViewPropertyAnimator(duration: 0.28, timingParameters: timing)
    animator.addAnimations {
      for lane in lanes { lane.transform = CGAffineTransform(translationX: direction * slotWidth, y: 0) }
    }
    animator.addCompletion { [weak self, weak overlay] _ in
      overlay?.removeFromSuperview()
      guard let self, skipAnimationID == animationID else { return }
      skipAnimator = nil
      skipOverlay = nil
      symbolView.alpha = 1
      if let pending = pendingSkipDirection {
        pendingSkipDirection = nil
        animateActivation(direction: pending)
      }
    }
    skipAnimator = animator
    animator.startAnimation()
  }

  #if DEBUG && targetEnvironment(simulator)
    var skipPresentationOffsets: [CGFloat]? {
      skipOverlay?.subviews.compactMap { $0.layer.presentation()?.transform.m41 }
    }

    var isRenderedSymbolSettled: Bool {
      func pixels(_ image: UIImage?) -> Data? {
        guard let image else { return nil }
        return UIGraphicsImageRenderer(size: bounds.size).image { _ in
          image.draw(at: CGPoint(x: (bounds.width - image.size.width) / 2,
            y: (bounds.height - image.size.height) / 2))
        }.pngData()
      }
      guard let rendered = pixels(symbolView.image), let expected = pixels(image(for: .normal)) else { return false }
      return rendered == expected && symbolAnimator == nil && skipAnimator == nil && skipOverlay == nil &&
        symbolView.alpha == 1 && symbolView.transform == .identity &&
        symbolContainer.transform == .identity &&
        abs(symbolView.center.x - symbolContainer.bounds.midX) < 0.5 &&
        abs(symbolView.center.y - symbolContainer.bounds.midY) < 0.5
    }
  #endif
}

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
  private weak var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?
  #if targetEnvironment(macCatalyst)
    private let volumeSlider = PlayerTrackSlider()
  #else
    private let volumeSlider = DragOnlySystemVolumeView(frame: .zero)
  #endif
  private var audioRouteTask: Task<Void, Never>?
  private var progressDisplayLink: CADisplayLink?
  private var isPlaybackPresentationActive = false
  private var isApplicationActive = UIApplication.shared.applicationState == .active
  private lazy var progressClock = PlayerProgressClock(owner: self)
  var isSmoothProgressRunning: Bool { progressDisplayLink != nil }
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
  weak var timeSlider: PlayerTrackSlider!
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
  weak var loudSpeaker: UIImageView!
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
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                 UIApplication.didEnterBackgroundNotification, .NSProcessInfoPowerStateDidChange] {
      NotificationCenter.default.addObserver(self, selector: #selector(progressEnvironmentChanged(_:)),
        name: name, object: nil)
    }

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
    timeSlider.accessibilityIdentifier = "player.playbackPosition"
    for label in [elapsedTimeLabel, remainingTimeLabel, audioInfoLabel] {
      label?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label?.textColor = .white.withAlphaComponent(0.65)
    }
    airplayButton.accessibilityLabel = "AirPlay"
    displayPlaylistButton.accessibilityLabel = "Playing next".localized
    lyricsButton.addTarget(self, action: #selector(lyricsPressed), for: .touchUpInside)

    playButton.imageView?.tintColor = .label
    previousButton.tintColor = .label
    nextButton.tintColor = .label
    skipBackwardButton.tintColor = .label
    skipForwardButton.tintColor = .label
    airplayButton.tintColor = .label
    playerModeButton.tintColor = .label
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
    loudSpeaker.tintColor = .white.withAlphaComponent(0.5)
    loudSpeaker.isAccessibilityElement = false
    volumeSlider.translatesAutoresizingMaskIntoConstraints = false
    #if targetEnvironment(macCatalyst)
      volumeSlider.minimumValue = 0
      volumeSlider.maximumValue = 1
      volumeSlider.value = player.volume
      volumeSlider.minimumTrackTintColor = .white.withAlphaComponent(0.7)
      volumeSlider.maximumTrackTintColor = .white.withAlphaComponent(0.18)
      volumeSlider.accessibilityLabel = "Volume".localized
      volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
    #else
      // MPVolumeView owns the system volume, including hardware buttons,
      // Control Center and output-route changes. AVAudioSession.outputVolume
      // is read-only; the player's separate gain must not drive this slider.
      volumeSlider.showsRouteButton = false
      volumeSlider.showsVolumeSlider = true
      volumeSlider.isTrackExpansionEnabled = true
      volumeSlider.tintColor = .white.withAlphaComponent(0.7)
      volumeSlider.setMinimumVolumeSliderImage(volumeTrackImage(alpha: 0.7), for: .normal)
      volumeSlider.setMaximumVolumeSliderImage(volumeTrackImage(alpha: 0.18), for: .normal)
      let invisibleThumb = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
      volumeSlider.setVolumeThumbImage(invisibleThumb, for: .normal)
    #endif
    addSubview(volumeSlider)

    let quietSpeaker = UIImageView(image: UIImage(systemName: "speaker.fill"))
    quietSpeaker.translatesAutoresizingMaskIntoConstraints = false
    quietSpeaker.contentMode = .scaleAspectFit
    quietSpeaker.tintColor = .white.withAlphaComponent(0.5)
    addSubview(quietSpeaker)
    NSLayoutConstraint.activate([
      quietSpeaker.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
      quietSpeaker.centerYAnchor.constraint(equalTo: loudSpeaker.centerYAnchor),
      quietSpeaker.widthAnchor.constraint(equalToConstant: 16),
      quietSpeaker.heightAnchor.constraint(equalToConstant: 16),
      volumeSlider.leadingAnchor.constraint(equalTo: quietSpeaker.trailingAnchor, constant: 12),
      volumeSlider.trailingAnchor.constraint(equalTo: loudSpeaker.leadingAnchor, constant: -4),
      volumeSlider.centerYAnchor.constraint(equalTo: loudSpeaker.centerYAnchor),
      volumeSlider.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  #if !targetEnvironment(macCatalyst)
    private func volumeTrackImage(alpha: CGFloat) -> UIImage {
      let size = CGSize(width: 14, height: 7)
      return UIGraphicsImageRenderer(size: size).image { _ in
        UIColor.white.withAlphaComponent(alpha).setFill()
        UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3.5).fill()
      }.resizableImage(withCapInsets: UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
    }
  #endif

  private func configureIconControls() {
    // Keep the player controls as bare icons with their existing touch targets.
    for button in [playButton, previousButton, nextButton, skipBackwardButton,
                   skipForwardButton, airplayButton, playerModeButton] {
      guard let button else { continue }
      var configuration = UIButton.Configuration.player(isSelected: false)
      configuration.image = button.image(for: .normal)
      button.backgroundColor = .clear
      button.clipsToBounds = false
      button.configuration = configuration
    }
    for (button, symbol) in [(lyricsButton!, "quote.bubble"), (displayPlaylistButton!, "list.bullet")] {
      button.configurationUpdateHandler = { button in
        let color: UIColor = button.isSelected ? .black : .white
        var configuration = UIButton.Configuration.playerAccessory(isSelected: button.isSelected)
        configuration.image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal)
        if button.tintColor != color { button.tintColor = color }
        button.configuration = configuration
      }
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
    updateProgressClock()
  }

  func setPlaybackPresentationActive(_ active: Bool) {
    isPlaybackPresentationActive = active
    updateProgressClock()
  }

  @objc private func progressEnvironmentChanged(_ notification: Notification) {
    if notification.name == UIApplication.didBecomeActiveNotification { isApplicationActive = true }
    if notification.name == UIApplication.willResignActiveNotification ||
      notification.name == UIApplication.didEnterBackgroundNotification { isApplicationActive = false }
    updateProgressClock()
  }

  private func updateProgressClock() {
    let running = isPlaybackPresentationActive && isApplicationActive && window != nil &&
      player.isPlaying && player.currentlyPlaying?.isRadio == false && timeSlider?.isEnabled == true
    guard running else {
      progressDisplayLink?.invalidate()
      progressDisplayLink = nil
      return
    }
    if progressDisplayLink == nil {
      let link = CADisplayLink(target: progressClock, selector: #selector(PlayerProgressClock.tick(_:)))
      link.add(to: .main, forMode: .common)
      progressDisplayLink = link
    }
    let rate: Float = ProcessInfo.processInfo.isLowPowerModeEnabled ? 15 : 30
    progressDisplayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
  }

  fileprivate func refreshSmoothProgress() {
    guard let timeSlider, !timeSlider.isTracking, isPlaybackPresentationActive,
          isApplicationActive, player.isPlaying else { return }
    // Sample the audio engine's actual playhead: buffering, seeking and playback
    // speed remain authoritative. Do not advance an estimated one-second timer.
    let elapsed = player.elapsedTime
    guard elapsed.isFinite, elapsed >= 0 else { return }
    let value = min(timeSlider.maximumValue, max(timeSlider.minimumValue, Float(elapsed)))
    if value != timeSlider.value { timeSlider.setValue(value, animated: false) }
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

  #if targetEnvironment(macCatalyst)
    @objc
    private func volumeChanged() {
      player.volume = volumeSlider.value
    }
  #endif

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
    lyricsButton.tintColor = selected ? .black : .white
    lyricsButton.isSelected = selected
    lyricsButton.configuration = configuration
    lyricsButton.isEnabled = playerHandler?.isLyricsButtonAllowedToDisplay ?? false
    lyricsButton.accessibilityLabel = selected ? "Hide Lyrics".localized : "Show Lyrics".localized
  }

  @IBAction
  func playButtonPushed(_ sender: Any) {
    (playButton as? PlayerTransportButton)?.animateActivation()
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    (previousButton as? PlayerTransportButton)?.animateActivation(direction: player.playerMode == .music ? -1 : 0)
    playerHandler?.previousButtonPushed()
  }

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    (nextButton as? PlayerTransportButton)?.animateActivation(direction: player.playerMode == .music ? 1 : 0)
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
    updateProgressClock()
  }

  func refreshView() {
    refreshPlayer()
  }

  func refreshPlayer() {
    // Playback and metadata changes must not overwrite a settled output icon
    // using a transient route snapshot. Route notifications own that update.
    #if targetEnvironment(macCatalyst)
      if !volumeSlider.isTracking {
        volumeSlider.value = player.volume
      }
    #endif
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
    updateProgressClock()
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

// CADisplayLink retains its target. Keep the owner weak so a dismissed player
// cannot retain an animation clock or the complete player hierarchy.
@MainActor
private final class PlayerProgressClock: NSObject {
  weak var owner: PlayerControlView?
  init(owner: PlayerControlView) { self.owner = owner }
  @objc func tick(_ link: CADisplayLink) {
    guard let owner else { link.invalidate(); return }
    owner.refreshSmoothProgress()
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

#if DEBUG && targetEnvironment(simulator)
  @MainActor
  func verifyPlayerTransportMotion(_ button: PlayerTransportButton, direction: CGFloat,
                                  name: String, action: () -> Void) async throws {
    func require(_ condition: Bool, _ detail: String) throws {
      if !condition {
        throw NSError(domain: "PlayerTransportSmoke", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "\(name): \(detail)"])
      }
    }
    button.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(350))
    try require(button.window != nil && button.isRenderedSymbolSettled, "initial glyph is not ready")
    let size = button.bounds.size
    func frame() -> UIImage {
      UIGraphicsImageRenderer(size: size).image { context in
        UIColor.darkGray.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        (button.layer.presentation() ?? button.layer).render(in: context.cgContext)
      }
    }
    var frames = [frame()]
    button.isHighlighted = true
    try await Task.sleep(for: .milliseconds(100))
    frames.append(frame())
    button.isHighlighted = false
    action()
    var offsets: [CGFloat] = []
    for _ in 0..<14 {
      try await Task.sleep(for: .milliseconds(25))
      frames.append(frame())
      if let offset = button.skipPresentationOffsets?.first { offsets.append(offset) }
    }
    try require(button.isRenderedSymbolSettled, "release left a stale, scaled or off-center glyph")
    if direction != 0 && !UIAccessibility.isReduceMotionEnabled {
      try require(offsets.count >= 3 && abs(offsets.last! - offsets.first!) > 1,
        "skip did not move through real presentation frames: \(offsets)")
      try require(zip(offsets, offsets.dropFirst()).allSatisfy { ($0.1 - $0.0) * direction >= -0.1 },
        "skip reversed or jumped mid-flight: \(offsets)")
      button.animateActivation(direction: direction)
      try await Task.sleep(for: .milliseconds(60))
      let before = button.skipPresentationOffsets?.first
      button.animateActivation(direction: direction)
      button.animateActivation(direction: direction)
      try await Task.sleep(for: .milliseconds(30))
      if let before, let after = button.skipPresentationOffsets?.first {
        try require((after - before) * direction >= -0.1, "rapid taps restarted the visible flight")
      } else {
        try require(false, "rapid taps removed the visible flight")
      }
      try await Task.sleep(for: .milliseconds(650))
      try require(button.isRenderedSymbolSettled, "rapid skips left an overlay or hidden original")
      guard let original = button.image(for: .normal) else {
        try require(false, "missing configured skip image"); return
      }
      button.animateActivation(direction: direction)
      let replacement = UIImage.play.withConfiguration(UIImage.SymbolConfiguration(pointSize: 20))
      button.setImage(replacement, for: .normal)
      button.configuration?.image = replacement
      button.renderSymbol(replacement, identifier: "smoke-replacement")
      try require(button.skipPresentationOffsets == nil, "symbol replacement retained flying lanes")
      try await Task.sleep(for: .milliseconds(350))
      try require(button.isRenderedSymbolSettled, "replacement left a stale or hidden glyph")
      button.setImage(original, for: .normal)
      button.configuration?.image = original
      button.renderSymbol(original, identifier: direction > 0 ? "forward" : "backward")
      try await Task.sleep(for: .milliseconds(350))
      try require(button.isRenderedSymbolSettled, "restoring the skip glyph did not settle")
    }
    button.isHighlighted = true
    try await Task.sleep(for: .milliseconds(60))
    button.isHighlighted = false // Cancelled press: no playback action.
    try await Task.sleep(for: .milliseconds(220))
    try require(button.isRenderedSymbolSettled, "cancelled press did not restore its glyph")
    let gridSize = CGSize(width: size.width * 8, height: size.height * 2)
    let grid = UIGraphicsImageRenderer(size: gridSize).image { context in
      UIColor.darkGray.setFill()
      context.fill(CGRect(origin: .zero, size: gridSize))
      for (index, image) in frames.enumerated() {
        image.draw(at: CGPoint(x: CGFloat(index % 8) * size.width,
          y: CGFloat(index / 8) * size.height))
      }
    }
    try grid.pngData()?.write(to: URL.documentsDirectory.appendingPathComponent("\(name).png"))
    NSLog("PlayerTransportSmoke: %@ passed presentation motion, rapid taps, interruption and cancellation", name)
  }
#endif
