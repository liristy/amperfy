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
    static let activeTrackScale: CGFloat = 11.0 / 7.0
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
      let scale = expanded ? Self.activeTrackScale : 1
      let transform = CGAffineTransform(scaleX: 1, y: scale)
      guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
        trackPresentation.layer.removeAllAnimations()
        trackPresentation.transform = transform
        return
      }
      UIView.animate(withDuration: expanded ? 0.16 : 0.2, delay: 0,
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

// Consume touches before they reach UISlider's own thumbless press animation.
// The native slider is a sibling, so its gesture recognizers cannot observe these touches.
private final class SliderTouchSurface: UIView {
  weak var slider: PlayerTrackSlider?

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first else { return }
    _ = slider?.beginTracking(touch, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let touch = touches.first, slider?.isTracking == true else { return }
    _ = slider?.continueTracking(touch, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard slider?.isTracking == true else { return }
    slider?.endTracking(touches.first, with: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    slider?.cancelTracking(with: event)
  }
}

private final class FixedTrackSlider: UISlider {
  var restingTrackHeight: CGFloat = 7

  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    let track = super.trackRect(forBounds: bounds)
    let height = min(bounds.height, restingTrackHeight)
    return CGRect(x: track.minX, y: bounds.midY - height / 2, width: track.width, height: height)
  }
}

class PlayerTrackSlider: UIControl {
  static let standardRestingTrackHeight: CGFloat = 7
  static let standardActiveTrackHeight: CGFloat = 8.5
  var restingTrackHeight: CGFloat = PlayerTrackSlider.standardRestingTrackHeight {
    didSet { nativeSlider.restingTrackHeight = restingTrackHeight; nativeSlider.setNeedsLayout() }
  }
  var activeTrackHeight: CGFloat = PlayerTrackSlider.standardActiveTrackHeight
  private var isTrackExpanded = false
  private var scrubStartValue: Float?
  private var trackAnimator: UIViewPropertyAnimator?
  private var lastTouchLocation = CGPoint.zero
  private let nativeSlider = FixedTrackSlider()
  private let trackPresentation = UIView()
  private let touchSurface = SliderTouchSurface()

  var value: Float {
    get { nativeSlider.value }
    set { nativeSlider.value = newValue }
  }
  var minimumValue: Float {
    get { nativeSlider.minimumValue }
    set { nativeSlider.minimumValue = newValue }
  }
  var maximumValue: Float {
    get { nativeSlider.maximumValue }
    set { nativeSlider.maximumValue = newValue }
  }
  var isContinuous: Bool = true
  var minimumTrackTintColor: UIColor? {
    get { nativeSlider.minimumTrackTintColor }
    set { nativeSlider.minimumTrackTintColor = newValue }
  }
  var maximumTrackTintColor: UIColor? {
    get { nativeSlider.maximumTrackTintColor }
    set { nativeSlider.maximumTrackTintColor = newValue }
  }
  var preferredBehavioralStyle: UIBehavioralStyle {
    get { nativeSlider.preferredBehavioralStyle }
    set { nativeSlider.preferredBehavioralStyle = newValue }
  }
  var sliderStyle: UISlider.Style {
    get { nativeSlider.sliderStyle }
    set { nativeSlider.sliderStyle = newValue }
  }

  func setValue(_ value: Float, animated: Bool) { nativeSlider.setValue(value, animated: animated) }

  override var accessibilityLabel: String? {
    didSet { nativeSlider.accessibilityLabel = accessibilityLabel }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureTouchSurface()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureTouchSurface()
  }

  private func configureTouchSurface() {
    isAccessibilityElement = false
    nativeSlider.isAccessibilityElement = true
    nativeSlider.addTarget(self, action: #selector(nativeValueChanged), for: .valueChanged)
    trackPresentation.addSubview(nativeSlider)
    addSubview(trackPresentation)
    touchSurface.slider = self
    touchSurface.isAccessibilityElement = false
    touchSurface.backgroundColor = .clear
    addSubview(touchSurface)
  }

  @objc private func nativeValueChanged() {
    // Keep VoiceOver's native adjustable control and its value announcements.
    sendActions(for: .valueChanged)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    trackPresentation.bounds = bounds
    trackPresentation.center = CGPoint(x: bounds.midX, y: bounds.midY)
    nativeSlider.frame = trackPresentation.bounds
    touchSurface.frame = bounds
    bringSubviewToFront(touchSurface)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard isEnabled, isUserInteractionEnabled, !isHidden, alpha > 0.01,
          self.point(inside: point, with: event) else { return nil }
    return touchSurface
  }

  // Playback refresh and the player's dismissal gesture must see our drag even
  // though the native slider only displays values and remains unpressed.
  override var isTracking: Bool { scrubStartValue != nil }

  func trackRect(forBounds bounds: CGRect) -> CGRect { nativeSlider.trackRect(forBounds: bounds) }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    beginScrubbing(at: touch.location(in: self))
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    finishScrubbing(at: touch?.location(in: self), cancelled: false)
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    continueScrubbing(at: touch.location(in: self))
  }

  override func cancelTracking(with event: UIEvent?) {
    finishScrubbing(cancelled: true)
  }

  private func beginScrubbing(at point: CGPoint) -> Bool {
    guard isEnabled, maximumValue > minimumValue,
          trackRect(forBounds: bounds).width > 0 else { return false }
    scrubStartValue = value
    lastTouchLocation = point
    setTrackExpanded(true)
    sendActions(for: .touchDown)
    updateScrubValue(at: point)
    sendActions(for: .touchDragInside)
    return true
  }

  private func continueScrubbing(at point: CGPoint) -> Bool {
    guard isTracking, isEnabled else { return false }
    lastTouchLocation = point
    updateScrubValue(at: point)
    sendActions(for: bounds.contains(point) ? .touchDragInside : .touchDragOutside)
    return true
  }

  private func updateScrubValue(at point: CGPoint) {
    let track = trackRect(forBounds: bounds)
    guard track.width > 0, point.x.isFinite else { return }
    var fraction = min(1, max(0, (point.x - track.minX) / track.width))
    if effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
    let nextValue = minimumValue + Float(fraction) * (maximumValue - minimumValue)
    guard nextValue != value else { return }
    setValue(nextValue, animated: false)
    if isContinuous { sendActions(for: .valueChanged) }
  }

  private func finishScrubbing(at point: CGPoint? = nil, cancelled: Bool, animated: Bool = true) {
    if let initialValue = scrubStartValue {
      if cancelled {
        if !isContinuous {
          setValue(initialValue, animated: false)
          sendActions(for: .touchDragInside)
        }
      } else if let point {
        lastTouchLocation = point
        updateScrubValue(at: point)
      }
      scrubStartValue = nil
      if !cancelled, !isContinuous { sendActions(for: .valueChanged) }
      let completion: UIControl.Event = cancelled ? .touchCancel :
        (bounds.contains(lastTouchLocation) ? .touchUpInside : .touchUpOutside)
      sendActions(for: completion)
    }
    setTrackExpanded(false, animated: animated)
  }

  override var isEnabled: Bool {
    didSet {
      nativeSlider.isEnabled = isEnabled
      if !isEnabled { finishScrubbing(cancelled: true, animated: false) }
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { finishScrubbing(cancelled: true, animated: false) }
  }

  private func setTrackExpanded(_ expanded: Bool, animated: Bool = true) {
    guard expanded != isTrackExpanded || !animated else { return }
    isTrackExpanded = expanded
    // Freeze an interrupted press at its rendered height. UIView's implicit
    // beginFromCurrentState can carry the growing velocity into a release.
    if let animator = trackAnimator, animator.state == .active {
      animator.stopAnimation(false)
      animator.finishAnimation(at: .current)
    }
    trackAnimator = nil
    let restingHeight = min(bounds.height, restingTrackHeight)
    let activeHeight = min(bounds.height, activeTrackHeight)
    let scale = expanded && restingHeight > 0 ? activeHeight / restingHeight : 1
    let target = CGAffineTransform(scaleX: 1, y: scale)
    guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
      trackPresentation.layer.removeAllAnimations()
      trackPresentation.transform = target
      return
    }
    // Match the volume control's timing and easing, with explicit interruption.
    let animator = UIViewPropertyAnimator(duration: expanded ? 0.16 : 0.2, curve: .easeInOut) { [weak self] in
      self?.trackPresentation.transform = target
    }
    animator.addCompletion { [weak self, weak animator] _ in
      guard let self, trackAnimator === animator else { return }
      trackAnimator = nil
    }
    trackAnimator = animator
    animator.startAnimation()
  }

  #if DEBUG && targetEnvironment(simulator)
    func beginTrackingForSmoke(at point: CGPoint? = nil) {
      let track = trackRect(forBounds: bounds)
      var fraction = CGFloat((value - minimumValue) / max(0.001, maximumValue - minimumValue))
      if effectiveUserInterfaceLayoutDirection == .rightToLeft { fraction = 1 - fraction }
      _ = beginScrubbing(at: point ?? CGPoint(x: track.minX + track.width * fraction, y: track.midY))
    }

    func continueTrackingForSmoke(at point: CGPoint) { _ = continueScrubbing(at: point) }
    var isNativeTrackingForSmoke: Bool { nativeSlider.isTracking || nativeSlider.isHighlighted }

    var renderedTrackHeightForSmoke: CGFloat {
      let scale = (trackPresentation.layer.presentation() ?? trackPresentation.layer).transform.m22
      return trackRect(forBounds: bounds).height * scale
    }
  #endif
}

class SeekableTimeSlider: PlayerTrackSlider {
  static let verticalHitAreaExpansion: CGFloat = 20
  static let horizontalHitAreaExpansion: CGFloat = 8

  override init(frame: CGRect) {
    super.init(frame: frame)
    isContinuous = false
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    isContinuous = false
  }

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
