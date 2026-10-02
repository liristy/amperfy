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
  private final class LayoutReportingSystemVolumeView: MPVolumeView {
    var didLayout: (() -> Void)?

    override func layoutSubviews() {
      super.layoutSubviews()
      didLayout?()
    }
  }

  final class DragOnlySystemVolumeView: UIView, UIGestureRecognizerDelegate {
    private let systemVolume = LayoutReportingSystemVolumeView(frame: .zero)
    private let touchSurface = UIView()
    private weak var trackedSlider: UISlider?
    private var volumeDrag: RelativeVolumeDrag?
    private var routeObserver: AnyCancellable?
    private lazy var volumePan = UIPanGestureRecognizer(target: self, action: #selector(dragVolume(_:)))

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
      addSubview(systemVolume)
      touchSurface.backgroundColor = .clear
      touchSurface.isOpaque = false
      touchSurface.isAccessibilityElement = false
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
      systemVolume.bounds = CGRect(origin: .zero, size: bounds.size)
      systemVolume.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
    }

    private func cancelVolumeDragForRouteChange() {
      finishVolumeDrag(cancelled: true)
      volumePan.isEnabled = false
      volumePan.isEnabled = true
    }
  }
#endif

class PlayerTrackSlider: UISlider {
  var restingTrackHeight: CGFloat = 7
  var activeTrackHeight: CGFloat = 11

  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    let track = super.trackRect(forBounds: bounds)
    let height = min(bounds.height, isTracking ? activeTrackHeight : restingTrackHeight)
    return CGRect(x: track.minX, y: bounds.midY - height / 2, width: track.width, height: height)
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
