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
struct RelativeSliderDrag {
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

// Measured from the user's 60 fps Apple Music recording (13.86–15.70 s).
// Animate the capsule's geometry, not a stretched bitmap with elliptical ends.
final class PlayerSliderTrackView: UIView {
  static let standardRestingHeight: CGFloat = 7
  static let standardActiveHeight: CGFloat = 17
  static let activeWidthScale: CGFloat = 1.05
  static let animationDuration: TimeInterval = 0.55
  private let track = CAGradientLayer()
  private var trackRect = CGRect.zero
  private var expanded = false
  var restingHeight: CGFloat = PlayerSliderTrackView.standardRestingHeight
  var activeHeight: CGFloat = PlayerSliderTrackView.standardActiveHeight
  var minimumColor = UIColor.white.withAlphaComponent(0.7) { didSet { updateColors() } }
  var maximumColor = UIColor.white.withAlphaComponent(0.26) { didSet { updateColors() } }
  var isRightToLeft = false {
    didSet {
      guard oldValue != isRightToLeft else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      track.startPoint = CGPoint(x: isRightToLeft ? 1 : 0, y: 0.5)
      track.endPoint = CGPoint(x: isRightToLeft ? 0 : 1, y: 0.5)
      CATransaction.commit()
    }
  }
  var fraction: CGFloat = 0 {
    didSet {
      let value = min(1, max(0, fraction))
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      track.locations = [0, NSNumber(value: Double(value)), NSNumber(value: Double(value)), 1]
      CATransaction.commit()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    track.startPoint = CGPoint(x: 0, y: 0.5)
    track.endPoint = CGPoint(x: 1, y: 0.5)
    track.masksToBounds = true
    track.locations = [0, 0, 0, 1]
    layer.addSublayer(track)
    updateColors()
  }

  required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

  private var colors: [CGColor] {
    let fill = expanded ? minimumColor.withAlphaComponent(1) : minimumColor
    return [fill.cgColor, fill.cgColor, maximumColor.cgColor, maximumColor.cgColor]
  }

  private func updateColors() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.colors = colors
    CATransaction.commit()
  }

  func layoutTrack(in rect: CGRect) {
    guard trackRect != rect else { return }
    trackRect = rect
    setExpanded(expanded, animated: false)
  }

  static func spring(keyPath: String, expanded: Bool, from: Any, to: Any) -> CASpringAnimation {
    let animation = CASpringAnimation(keyPath: keyPath)
    animation.mass = 1
    animation.stiffness = expanded ? 275.56 : 246.49
    animation.damping = expanded ? 24.9 : 19.782
    animation.initialVelocity = 0
    animation.fromValue = from
    animation.toValue = to
    animation.duration = animationDuration
    return animation
  }

  func setExpanded(_ expanded: Bool, animated: Bool = true) {
    let current = track.presentation() ?? track
    let oldBounds = current.bounds
    let oldRadius = current.cornerRadius
    let oldColors = current.colors ?? colors
    self.expanded = expanded
    track.speed = 1
    track.timeOffset = 0
    track.beginTime = 0
    track.removeAllAnimations()
    let canExpand = activeHeight > restingHeight
    let width = trackRect.width * (expanded && canExpand ? Self.activeWidthScale : 1)
    let height = expanded ? activeHeight : restingHeight
    let targetBounds = CGRect(x: 0, y: 0, width: width, height: height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    track.position = CGPoint(x: trackRect.midX, y: trackRect.midY)
    track.bounds = targetBounds
    track.cornerRadius = height / 2
    track.colors = colors
    CATransaction.commit()
    guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
    let geometry = Self.spring(keyPath: "bounds", expanded: expanded,
      from: NSValue(cgRect: oldBounds), to: NSValue(cgRect: targetBounds))
    let radius = Self.spring(keyPath: "cornerRadius", expanded: expanded, from: oldRadius, to: height / 2)
    let color = CABasicAnimation(keyPath: "colors")
    color.fromValue = oldColors
    color.toValue = colors
    color.duration = expanded ? 0.12 : 0.2
    color.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    let group = CAAnimationGroup()
    group.animations = [geometry, radius, color]
    group.duration = Self.animationDuration
    group.beginTime = track.convertTime(CACurrentMediaTime(), from: nil)
    track.add(group, forKey: "player-slider-feedback")
  }

  #if DEBUG && targetEnvironment(simulator)
    var renderedBounds: CGRect { (track.presentation() ?? track).bounds }
    func pauseAnimation(at fraction: CGFloat) -> Bool {
      guard let animation = track.animation(forKey: "player-slider-feedback") else { return false }
      track.speed = 0
      track.timeOffset = animation.beginTime + animation.duration * Double(min(1, max(0, fraction)))
      return true
    }
  #endif
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
    private let feedbackTrack = PlayerSliderTrackView(frame: .zero)
    private let touchSurface = VolumeTouchSurface()
    private var isTouchPressed = false
    private var isTrackExpanded = false
    private weak var trackedSlider: UISlider?
    private var volumeDrag: RelativeSliderDrag?
    private var routeObserver: AnyCancellable?
    private var volumeObserver: AnyCancellable?
    var onExpansionChanged: ((Bool) -> Void)?
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
      addSubview(feedbackTrack)
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
      volumeObserver = AVAudioSession.sharedInstance().publisher(for: \.outputVolume, options: [.initial, .new])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] value in
          guard let self, volumeDrag == nil else { return }
          feedbackTrack.fraction = CGFloat(value)
        }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      // Native geometry and drag coordinates stay fixed. The separate capsule
      // renderer expands in both axes around the native track's aligned center.
      trackPresentation.bounds = bounds
      trackPresentation.center = CGPoint(x: bounds.midX, y: bounds.midY)
      feedbackTrack.frame = bounds
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
      if slider.minimumTrackTintColor != .clear { slider.minimumTrackTintColor = .clear }
      if slider.maximumTrackTintColor != .clear { slider.maximumTrackTintColor = .clear }
      feedbackTrack.layoutTrack(in: slider.convert(slider.trackRect(forBounds: slider.bounds), to: self))
      if volumeDrag == nil {
        feedbackTrack.fraction = CGFloat((slider.value - slider.minimumValue) /
          max(0.001, slider.maximumValue - slider.minimumValue))
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
              let drag = RelativeSliderDrag(value: slider.value, minimum: slider.minimumValue,
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
      feedbackTrack.fraction = CGFloat((slider.value - slider.minimumValue) /
        max(0.001, slider.maximumValue - slider.minimumValue))
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
      feedbackTrack.setExpanded(expanded)
      onExpansionChanged?(expanded)
    }

    private func cancelVolumeDragForRouteChange() {
      finishVolumeDrag(cancelled: true)
      volumePan.isEnabled = false
      volumePan.isEnabled = true
    }

    #if DEBUG && targetEnvironment(simulator)
      func setTouchPressedForSmoke(_ pressed: Bool) { setTouchPressed(pressed) }
      func cancelTouchForSmoke() { cancelVolumeDragForRouteChange() }
      var renderedTrackHeightForSmoke: CGFloat { feedbackTrack.renderedBounds.height }
      var renderedTrackWidthForSmoke: CGFloat { feedbackTrack.renderedBounds.width }
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
  static let standardActiveTrackHeight: CGFloat = 17
  var restingTrackHeight: CGFloat = PlayerTrackSlider.standardRestingTrackHeight {
    didSet {
      nativeSlider.restingTrackHeight = restingTrackHeight
      trackPresentation.restingHeight = restingTrackHeight
      setNeedsLayout()
    }
  }
  var activeTrackHeight: CGFloat = PlayerTrackSlider.standardActiveTrackHeight {
    didSet { trackPresentation.activeHeight = activeTrackHeight }
  }
  var onExpansionChanged: ((Bool) -> Void)?
  private var isTrackExpanded = false
  private var scrubStartValue: Float?
  private var scrubDrag: RelativeSliderDrag?
  private var scrubStartPoint = CGPoint.zero
  private var didScrub = false
  private var lastTouchLocation = CGPoint.zero
  private let nativeSlider = FixedTrackSlider()
  private let trackPresentation = PlayerSliderTrackView(frame: .zero)
  private let touchSurface = SliderTouchSurface()

  var value: Float {
    get { nativeSlider.value }
    set { nativeSlider.value = newValue; updateTrackValue() }
  }
  var minimumValue: Float {
    get { nativeSlider.minimumValue }
    set { nativeSlider.minimumValue = newValue; updateTrackValue() }
  }
  var maximumValue: Float {
    get { nativeSlider.maximumValue }
    set { nativeSlider.maximumValue = newValue; updateTrackValue() }
  }
  var isContinuous: Bool = true
  var minimumTrackTintColor: UIColor? {
    get { trackPresentation.minimumColor }
    set { trackPresentation.minimumColor = newValue ?? tintColor }
  }
  var maximumTrackTintColor: UIColor? {
    get { trackPresentation.maximumColor }
    set { trackPresentation.maximumColor = newValue ?? .clear }
  }
  var preferredBehavioralStyle: UIBehavioralStyle {
    get { nativeSlider.preferredBehavioralStyle }
    set { nativeSlider.preferredBehavioralStyle = newValue }
  }
  var sliderStyle: UISlider.Style {
    get { nativeSlider.sliderStyle }
    set { nativeSlider.sliderStyle = newValue }
  }

  func setValue(_ value: Float, animated: Bool) {
    nativeSlider.setValue(value, animated: false)
    updateTrackValue()
  }

  private func updateTrackValue() {
    trackPresentation.isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
    trackPresentation.fraction = CGFloat((value - minimumValue) / max(0.001, maximumValue - minimumValue))
  }

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
    nativeSlider.minimumTrackTintColor = .clear
    nativeSlider.maximumTrackTintColor = .clear
    nativeSlider.setThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }, for: .normal)
    nativeSlider.addTarget(self, action: #selector(nativeValueChanged), for: .valueChanged)
    addSubview(trackPresentation)
    addSubview(nativeSlider)
    touchSurface.slider = self
    touchSurface.isAccessibilityElement = false
    touchSurface.backgroundColor = .clear
    addSubview(touchSurface)
  }

  @objc private func nativeValueChanged() {
    // Keep VoiceOver's native adjustable control and its value announcements.
    updateTrackValue()
    sendActions(for: .valueChanged)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    trackPresentation.frame = bounds
    nativeSlider.frame = bounds
    trackPresentation.layoutTrack(in: nativeSlider.trackRect(forBounds: bounds))
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
    scrubDrag = RelativeSliderDrag(value: value, minimum: minimumValue, maximum: maximumValue,
      width: trackRect(forBounds: bounds).width)
    scrubStartPoint = point
    didScrub = false
    lastTouchLocation = point
    setTrackExpanded(true)
    sendActions(for: .touchDown)
    // Apple Music grabs the current value; landing anywhere on the rail must not seek.
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
    guard let scrubDrag, point.x.isFinite else { return }
    let direction: CGFloat = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
    let nextValue = scrubDrag.value(forTranslationX: (point.x - scrubStartPoint.x) * direction)
    guard nextValue != value else { return }
    didScrub = true
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
      scrubDrag = nil
      if !cancelled, !isContinuous, didScrub { sendActions(for: .valueChanged) }
      let completion: UIControl.Event = cancelled ? .touchCancel :
        (bounds.contains(lastTouchLocation) ? .touchUpInside : .touchUpOutside)
      sendActions(for: completion)
    }
    setTrackExpanded(false, animated: animated)
  }

  override var isEnabled: Bool {
    didSet {
      nativeSlider.isEnabled = isEnabled
      trackPresentation.alpha = isEnabled ? 1 : 0.4
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
    trackPresentation.setExpanded(expanded, animated: animated)
    onExpansionChanged?(expanded)
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

    func pauseTrackAnimationForSmoke(at fraction: CGFloat) -> Bool {
      trackPresentation.pauseAnimation(at: fraction)
    }

    var renderedTrackHeightForSmoke: CGFloat {
      trackPresentation.renderedBounds.height
    }
    var renderedTrackWidthForSmoke: CGFloat { trackPresentation.renderedBounds.width }
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
