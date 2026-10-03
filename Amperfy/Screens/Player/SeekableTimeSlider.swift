//
//  SeekableTimeSlider.swift
//  Amperfy
//
//  Created by Jerome Gangneux for Amperfy on 2026-03-02.
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

import AVFAudio
import Combine
import MediaPlayer
import UIKit

// A drag starts from the current level, independent of where the finger lands.
struct RelativeVolumeDrag {
  let initialValue: Float
  let minimumValue: Float
  let maximumValue: Float
  let trackWidth: CGFloat

  init?(value: Float, minimum: Float, maximum: Float, width: CGFloat) {
    guard value.isFinite, minimum.isFinite, maximum.isFinite,
          maximum > minimum, width.isFinite, width > 0 else { return nil }
    initialValue = min(maximum, max(minimum, value))
    minimumValue = minimum
    maximumValue = maximum
    trackWidth = width
  }

  func value(forTranslationX translation: CGFloat) -> Float {
    guard translation.isFinite else { return initialValue }
    let delta = Float(translation / trackWidth) * (maximumValue - minimumValue)
    return min(maximumValue, max(minimumValue, initialValue + delta))
  }
}

#if !targetEnvironment(macCatalyst)
  private final class VolumeTouchSurface: UIView {
    var touchChanged: ((Bool) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesBegan(touches, with: event)
      touchChanged?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesEnded(touches, with: event)
      touchChanged?(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesCancelled(touches, with: event)
      touchChanged?(false)
    }
  }

  private final class LayoutReportingSystemVolumeView: MPVolumeView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
      super.layoutSubviews()
      didLayout?()
    }
  }

  final class DragOnlySystemVolumeView: UIView, UIGestureRecognizerDelegate {
    private let systemVolume = LayoutReportingSystemVolumeView(frame: .zero)
    private let trackPresentation = UIView()
    private let touchSurface = VolumeTouchSurface()
    private var isTouchPressed = false
    private var isTrackExpanded = false
    private weak var trackedSlider: UISlider?
    private var volumeDrag: RelativeVolumeDrag?
    private var routeObserver: AnyCancellable?
    private lazy var volumePan = UIPanGestureRecognizer(target: self, action: #selector(dragVolume(_:)))

    var isTrackExpansionEnabled = false {
      didSet { updateTrackInteraction() }
    }

    var showsRouteButton: Bool {
      get { systemVolume.showsRouteButton }
      set { systemVolume.showsRouteButton = newValue }
    }

    var showsVolumeSlider: Bool {
      get { systemVolume.showsVolumeSlider }
      set { systemVolume.showsVolumeSlider = newValue }
    }

    func setMinimumVolumeSliderImage(_ image: UIImage?, for state: UIControl.State) {
      systemVolume.setMinimumVolumeSliderImage(image, for: state)
    }

    func setMaximumVolumeSliderImage(_ image: UIImage?, for state: UIControl.State) {
      systemVolume.setMaximumVolumeSliderImage(image, for: state)
    }

    func setVolumeThumbImage(_ image: UIImage?, for state: UIControl.State) {
      systemVolume.setVolumeThumbImage(image, for: state)
    }

    override init(frame: CGRect) {
      super.init(frame: frame)
      configureDragging()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      configureDragging()
    }

    private func configureDragging() {
      showsRouteButton = false
      systemVolume.tintColor = tintColor
      systemVolume.didLayout = { [weak self] in self?.alignNativeTrack() }
      trackPresentation.addSubview(systemVolume)
      addSubview(trackPresentation)
      touchSurface.backgroundColor = .clear
      touchSurface.isOpaque = false
      touchSurface.isAccessibilityElement = false
      touchSurface.touchChanged = { [weak self] pressed in self?.setTouchPressed(pressed) }
      volumePan.maximumNumberOfTouches = 1
      volumePan.delegate = self
      touchSurface.addGestureRecognizer(volumePan)
      addSubview(touchSurface)
      routeObserver = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.cancelVolumeDragForRouteChange()
          }
        }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      // Animate a separate display layer around the aligned native track. Its
      // center and horizontal size stay fixed, as do the touch/drag coordinates.
      trackPresentation.bounds = bounds
      trackPresentation.center = CGPoint(x: bounds.midX, y: bounds.midY)
      systemVolume.bounds = CGRect(origin: .zero, size: bounds.size)
      systemVolume.center = CGPoint(x: trackPresentation.bounds.midX, y: trackPresentation.bounds.midY)
      systemVolume.layoutIfNeeded()
      alignNativeTrack()
      touchSurface.frame = bounds
      bringSubviewToFront(touchSurface)
    }

    private func alignNativeTrack() {
      guard let slider = nativeSlider(in: systemVolume) else { return }
      let track = slider.convert(slider.trackRect(forBounds: slider.bounds), to: systemVolume)
      guard track.width > 0, track.height > 0, track.midY.isFinite else { return }
      // Playback activation can lay out the native slider after our parent has
      // finished. Move the entire system view after each native layout; leave
      // UIKit's slider geometry untouched and calculate an absolute offset.
      let offset = systemVolume.bounds.midY - track.midY
      if abs(systemVolume.transform.ty - offset) > 0.25 {
        systemVolume.transform = CGAffineTransform(translationX: 0, y: offset)
      }
    }

    override func tintColorDidChange() {
      super.tintColorDidChange()
      systemVolume.tintColor = tintColor
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard isUserInteractionEnabled, !isHidden, alpha > 0.01, bounds.contains(point) else { return nil }
      // A tap must never reach UISlider.beginTracking and jump to its location.
      // Native slider accessibility actions remain available independently.
      return touchSurface
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        finishVolumeDrag(cancelled: true)
      } else {
        systemVolume.setNeedsLayout()
        setNeedsLayout()
      }
    }

    private func nativeSlider(in view: UIView) -> UISlider? {
      for child in view.subviews where child !== touchSurface {
        if let slider = child as? UISlider { return slider }
        if let slider = nativeSlider(in: child) { return slider }
      }
      return nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let slider = nativeSlider(in: systemVolume), slider.isEnabled, !slider.isHidden else { return false }
      let velocity = volumePan.velocity(in: self)
      return abs(velocity.x) > abs(velocity.y)
    }

    @objc private func dragVolume(_ pan: UIPanGestureRecognizer) {
      switch pan.state {
      case .began:
        guard let slider = nativeSlider(in: systemVolume), slider.isEnabled, !slider.isHidden,
              let drag = RelativeVolumeDrag(value: slider.value, minimum: slider.minimumValue,
                maximum: slider.maximumValue, width: slider.trackRect(forBounds: slider.bounds).width) else { return }
        trackedSlider = slider
        volumeDrag = drag
        updateTrackInteraction()
        slider.sendActions(for: .touchDown)
        applyVolumeDrag(translation: pan.translation(in: self).x)
      case .changed:
        applyVolumeDrag(translation: pan.translation(in: self).x)
      case .ended:
        applyVolumeDrag(translation: pan.translation(in: self).x)
        finishVolumeDrag(cancelled: false)
      case .cancelled, .failed:
        finishVolumeDrag(cancelled: true)
      default: break
      }
    }

    private func applyVolumeDrag(translation: CGFloat) {
      guard let slider = trackedSlider, slider.isEnabled, let drag = volumeDrag else { return }
      // Use only public UISlider properties/events on MPVolumeView's control.
      // MPVolumeView continues to own system-volume writes and external updates.
      slider.setValue(drag.value(forTranslationX: translation), animated: false)
      slider.sendActions(for: .valueChanged)
    }

    private func finishVolumeDrag(cancelled: Bool) {
      trackedSlider?.sendActions(for: cancelled ? .touchCancel : .touchUpInside)
      trackedSlider = nil
      volumeDrag = nil
      isTouchPressed = false
      updateTrackInteraction()
    }

    private func setTouchPressed(_ pressed: Bool) {
      if pressed {
        guard let slider = nativeSlider(in: systemVolume), slider.isEnabled, !slider.isHidden else { return }
      }
      isTouchPressed = pressed
      updateTrackInteraction()
    }

    private func updateTrackInteraction() {
      // A pan cancels the touch-surface events when it takes over; keep the
      // track expanded until that drag ends, rather than shrinking mid-drag.
      let expanded = isTrackExpansionEnabled && (isTouchPressed || volumeDrag != nil)
      guard expanded != isTrackExpanded else { return }
      isTrackExpanded = expanded
      let scale = expanded ? PlayerTrackSlider.standardActiveTrackHeight /
        PlayerTrackSlider.standardRestingTrackHeight : 1
      let transform = CGAffineTransform(scaleX: 1, y: scale)
      guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
        trackPresentation.layer.removeAllAnimations()
        trackPresentation.transform = transform
        return
      }
      UIView.animate(withDuration: expanded ? PlayerTrackSlider.standardExpansionDuration :
        PlayerTrackSlider.standardRestorationDuration, delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
        self.trackPresentation.transform = transform
      }
    }

    private func cancelVolumeDragForRouteChange() {
      finishVolumeDrag(cancelled: true)
      volumePan.isEnabled = false
      volumePan.isEnabled = true
    }

    #if DEBUG && targetEnvironment(simulator)
      func setTouchPressedForSmoke(_ pressed: Bool) { setTouchPressed(pressed) }
      func cancelTouchForSmoke() { cancelVolumeDragForRouteChange() }
    #endif
  }
#endif

class PlayerTrackSlider: UISlider {
  static let standardRestingTrackHeight: CGFloat = 7
  static let standardActiveTrackHeight: CGFloat = 11
  static let standardExpansionDuration: CFTimeInterval = 0.16
  static let standardRestorationDuration: CFTimeInterval = 0.28
  var restingTrackHeight: CGFloat = PlayerTrackSlider.standardRestingTrackHeight
  var activeTrackHeight: CGFloat = PlayerTrackSlider.standardActiveTrackHeight
  private var displayedTrackHeight: CGFloat?
  private var isTrackExpanded = false
  private var isTrackApplicationActive = UIApplication.shared.applicationState == .active
  private var trackHeightDisplayLink: CADisplayLink?
  private var trackHeightTransition: (from: CGFloat, to: CGFloat, start: CFTimeInterval,
                                      duration: CFTimeInterval)?
  private lazy var trackHeightClock = PlayerTrackHeightClock(owner: self)

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureTrackRestoration()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureTrackRestoration()
  }

  private func configureTrackRestoration() {
    addTarget(self, action: #selector(restoreTrack), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    for name in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                 UIApplication.didEnterBackgroundNotification, UIAccessibility.reduceMotionStatusDidChangeNotification] {
      NotificationCenter.default.addObserver(self, selector: #selector(trackEnvironmentChanged(_:)),
        name: name, object: nil)
    }
  }

  @objc private func restoreTrack() { setTrackExpanded(false) }

  @objc private func trackEnvironmentChanged(_ notification: Notification) {
    if notification.name == UIApplication.didBecomeActiveNotification { isTrackApplicationActive = true }
    if notification.name == UIApplication.willResignActiveNotification ||
      notification.name == UIApplication.didEnterBackgroundNotification {
      isTrackApplicationActive = false
      isTrackExpanded = false
      finishTrackHeightAnimation()
    } else if UIAccessibility.isReduceMotionEnabled {
      finishTrackHeightAnimation()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      cancelTracking(with: nil)
    }
  }

  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    let track = super.trackRect(forBounds: bounds)
    let height = min(bounds.height, displayedTrackHeight ?? restingTrackHeight)
    return CGRect(x: track.minX, y: bounds.midY - height / 2, width: track.width, height: height)
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    let accepted = super.beginTracking(touch, with: event)
    if accepted { setTrackExpanded(true) }
    return accepted
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    super.endTracking(touch, with: event)
    setTrackExpanded(false)
  }

  override func cancelTracking(with event: UIEvent?) {
    super.cancelTracking(with: event)
    setTrackExpanded(false)
  }

  private func setTrackExpanded(_ expanded: Bool) {
    guard window != nil, isTrackApplicationActive, !UIAccessibility.isReduceMotionEnabled else {
      isTrackExpanded = expanded
      finishTrackHeightAnimation()
      return
    }
    // UIKit can send a release action from super.endTracking before calling our
    // override. Repeating that action must not restart or finish the transition.
    guard expanded != isTrackExpanded else { return }
    isTrackExpanded = expanded
    let from = displayedTrackHeight ?? restingTrackHeight
    let to = expanded ? activeTrackHeight : restingTrackHeight
    stopTrackHeightClock()
    guard abs(from - to) > 0.01 else {
      finishTrackHeightAnimation()
      return
    }
    // trackRect reads an ordinary CGFloat, which UIView.animate cannot animate.
    // Interpolate that actual geometry, leaving touch coordinates and value intact.
    trackHeightTransition = (from, to, CACurrentMediaTime(), expanded ?
      Self.standardExpansionDuration : Self.standardRestorationDuration)
    let link = CADisplayLink(target: trackHeightClock, selector: #selector(PlayerTrackHeightClock.tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    trackHeightDisplayLink = link
    link.add(to: .main, forMode: .common)
  }

  fileprivate func advanceTrackHeight(at timestamp: CFTimeInterval) {
    guard let transition = trackHeightTransition else { return }
    guard window != nil, isTrackApplicationActive, !UIAccessibility.isReduceMotionEnabled else {
      finishTrackHeightAnimation()
      return
    }
    let progress = min(1, max(0, (timestamp - transition.start) / transition.duration))
    guard progress < 1 else {
      finishTrackHeightAnimation()
      return
    }
    let eased = CGFloat(progress * progress * (3 - 2 * progress))
    applyTrackHeight(transition.from + (transition.to - transition.from) * eased)
  }

  private func applyTrackHeight(_ height: CGFloat?) {
    displayedTrackHeight = height
    UIView.performWithoutAnimation {
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }
  }

  private func stopTrackHeightClock() {
    trackHeightDisplayLink?.invalidate()
    trackHeightDisplayLink = nil
    trackHeightTransition = nil
  }

  private func finishTrackHeightAnimation() {
    stopTrackHeightClock()
    applyTrackHeight(isTrackExpanded ? activeTrackHeight : nil)
  }

  #if DEBUG && targetEnvironment(simulator)
    func setTrackExpandedForSmoke(_ expanded: Bool) { setTrackExpanded(expanded) }
    var isTrackHeightAnimatingForSmoke: Bool { trackHeightDisplayLink != nil }
  #endif
}

@MainActor
private final class PlayerTrackHeightClock: NSObject {
  weak var owner: PlayerTrackSlider?
  init(owner: PlayerTrackSlider) { self.owner = owner }
  @objc func tick(_ link: CADisplayLink) {
    guard let owner else { link.invalidate(); return }
    owner.advanceTrackHeight(at: link.timestamp)
  }
}

class SeekableTimeSlider: PlayerTrackSlider {
  static let verticalHitAreaExpansion: CGFloat = 20
  static let horizontalHitAreaExpansion: CGFloat = 8

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let expandedBounds = bounds.inset(
      by: UIEdgeInsets(
        top: -Self.verticalHitAreaExpansion,
        left: -Self.horizontalHitAreaExpansion,
        bottom: -Self.verticalHitAreaExpansion,
        right: -Self.horizontalHitAreaExpansion
      )
    )
    return expandedBounds.contains(point)
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    guard isPointerSeekAllowed(touch) else {
      return super.beginTracking(touch, with: event)
    }
    updateValue(for: touch.location(in: self))
    return false
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    guard isPointerSeekAllowed(touch) else {
      return super.continueTracking(touch, with: event)
    }
    // For pointer/mouse: suppress drag seeking and UISlider's continuous drag behavior.
    return false
  }

  private func updateValue(for location: CGPoint) {
    guard let value = valueFromLocation(location) else { return }
    self.value = value
    sendActions(for: .valueChanged)
  }

  private func valueFromLocation(_ location: CGPoint) -> Float? {
    let trackRect = trackRect(forBounds: bounds)
    guard trackRect.width > 0 else { return nil }
    let clampedX = min(max(location.x, trackRect.minX), trackRect.maxX)
    let fraction = (clampedX - trackRect.minX) / trackRect.width
    return minimumValue + Float(fraction) * (maximumValue - minimumValue)
  }

  private func isPointerSeekAllowed(_ touch: UITouch) -> Bool {
    #if targetEnvironment(macCatalyst)
      return true
    #else
      return touch.type == .indirectPointer
    #endif
  }
}
