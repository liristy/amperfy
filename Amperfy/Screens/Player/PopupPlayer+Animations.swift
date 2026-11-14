//
//  PopupPlayer+Animations.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 12.02.24.
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
import UIKit

@MainActor
private final class PlayerTransitionCapsuleHeader: UIView {
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playIcon = UIImageView()
  private let nextIcon = UIImageView(image: UIImage(systemName: "forward.fill"))
  init(player: PlayerFacade) {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    titleLabel.text = player.currentlyPlaying?.title
    subtitleLabel.text = player.currentlyPlaying?.creatorName
    titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    subtitleLabel.font = .systemFont(ofSize: 9)
    titleLabel.textColor = .label
    subtitleLabel.textColor = .secondaryLabel
    playIcon.image = UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill")
    [playIcon, nextIcon].forEach { $0.contentMode = .scaleAspectFit; $0.tintColor = .label }
    [titleLabel, subtitleLabel, playIcon, nextIcon].forEach { addSubview($0) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = CGRect(x: 20, y: 4, width: max(0, bounds.width-112), height: 14)
    subtitleLabel.frame = CGRect(x: 20, y: 18, width: max(0, bounds.width-112), height: 12)
    playIcon.frame = CGRect(x: bounds.width-76, y: 7, width: 18, height: 18)
    nextIcon.frame = CGRect(x: bounds.width-44, y: 7, width: 22, height: 18)
  }
}

// The complete player expands from, and contracts into, the mini-player capsule.
// Keep the live content laid out at full size while its surface morphs in both axes.
// Never swap a rendered screenshot for the real player at the end of the animation.
@MainActor
final class PlayerSurfaceTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
  weak var sourcePlayer: UIView?
  weak var sourceArtwork: UIImageView?
  var interaction: UIPercentDrivenInteractiveTransition?
  var presentationInteraction: UIPercentDrivenInteractiveTransition?
  var artworkMotion: PlayerArtworkMotion?
  var artworkProgress: CGFloat = 0
  var artworkDestination: CGFloat?

  func updateArtwork(_ progress: CGFloat) {
    artworkProgress = min(1, max(0, progress))
    artworkMotion?.update(artworkProgress)
  }

  func finishArtwork(completed: Bool) {
    artworkDestination = completed ? 1 : 0
    artworkMotion?.settle(to: completed ? 1 : 0)
  }

  func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning? { presentationInteraction }

  func animationController(forPresented presented: UIViewController,
                           presenting: UIViewController, source: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
    PlayerSurfaceAnimator(isPresenting: true, sourcePlayer: sourcePlayer, sourceArtwork: sourceArtwork)
  }

  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    PlayerSurfaceAnimator(isPresenting: false, sourcePlayer: sourcePlayer, sourceArtwork: sourceArtwork)
  }

  func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning? { interaction }
}

// One rendered surface drives the mask and the shared cover. There is no second
// animation clock: the cover arrives when the surface first reaches its endpoint,
// then stays there. The closing cover follows a measured arc without scale bounce.
@MainActor
final class PlayerArtworkMotion: NSObject {
  private let player: UIView
  private let surface: UIView
  private let progressView: UIView
  private let foreground: [(view: UIView, transform: CGAffineTransform)]
  private let handle: UIView?
  private let handleTransform: CGAffineTransform
  private let cover: UIImageView?
  private let coverShadow: UIView?
  private let fullArtworkShadow: UIView?
  let smallFrame: CGRect
  private let fullFrame: CGRect
  private let presenting: Bool
  let startFrame: CGRect
  let endFrame: CGRect
  private let startRadius: CGFloat
  private let endRadius: CGFloat
  private let miniPlayer: UIView?
  private let miniTransform: CGAffineTransform
  private let miniAlpha: CGFloat
  private var progress: CGFloat = 0
  private var destination: CGFloat?
  private var displayLink: CADisplayLink?
  private var tracking: Bool
  private var trackingProgress: CGFloat = 0
  private var settleStartProgress: CGFloat = 0
  private var settleSurfaceFrame: CGRect?
  private var settleCoverFrame: CGRect?
  private var renderedSurfaceFrame: CGRect = .zero
  private let glass: UIVisualEffectView
  private let backdrop: UIView
  private let palette: UIView
  private let paletteAlpha: CGFloat
  private let capsuleHeader: UIView
  private let contentMasks: [UIView]
  private let manualDismissOpacity: Bool

  init(player: UIView, surface: UIView, progressView: UIView, smallFrame: CGRect, fullFrame: CGRect,
       presenting: Bool, cover: UIImageView?, coverShadow: UIView?, fullArtworkShadow: UIView?,
       endFrame: CGRect, endRadius: CGFloat,
       foreground: [UIView], handle: UIView?, miniPlayer: UIView?, interactive: Bool,
       glass: UIVisualEffectView, backdrop: UIView, palette: UIView, capsuleHeader: UIView, contentMasks: [UIView]) {
    self.player = player
    self.surface = surface
    self.progressView = progressView
    self.foreground = foreground.map { ($0, $0.transform) }
    self.handle = handle
    self.handleTransform = handle?.transform ?? .identity
    self.smallFrame = smallFrame
    self.fullFrame = fullFrame
    self.presenting = presenting
    self.cover = cover
    self.coverShadow = coverShadow
    self.fullArtworkShadow = fullArtworkShadow
    self.startFrame = cover?.frame ?? .zero
    self.endFrame = endFrame
    self.startRadius = cover?.layer.cornerRadius ?? 0
    self.endRadius = endRadius
    self.miniPlayer = miniPlayer
    self.miniTransform = miniPlayer?.transform ?? .identity
    self.miniAlpha = miniPlayer?.alpha ?? 1
    self.tracking = interactive
    self.glass = glass
    self.backdrop = backdrop
    self.palette = palette
    self.paletteAlpha = palette.alpha
    self.capsuleHeader = capsuleHeader
    self.contentMasks = contentMasks
    self.manualDismissOpacity = interactive && !presenting
    super.init()
    render(transition: 0)
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    let maximumRate = Float(player.window?.screen.maximumFramesPerSecond ?? 60)
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maximumRate,
                                                   preferred: maximumRate)
    displayLink = link
    link.add(to: .main, forMode: .common)
  }

  func update(_ value: CGFloat) {
    trackingProgress = value
    if tracking { render(transition: value) }
  }

  private func sample() {
    if tracking { render(transition: trackingProgress); return }
    // Read only the timing probe. Applying the page AND cover below in one
    // transaction avoids the extra frame caused by following the rendered page.
    guard let timing = progressView.layer.presentation() else { return }
    render(transition: timing.transform.m41)
  }

  private func render(transition: CGFloat) {
    let expansion = presenting ? transition : 1 - transition
    let current = min(1, max(0, transition))
    if let destination {
      progress = destination == 1 ? max(progress, current) : min(progress, current)
    } else {
      progress = current
    }
    var frame = CGRect(
      x: smallFrame.minX + (fullFrame.minX - smallFrame.minX) * expansion,
      y: smallFrame.minY + (fullFrame.minY - smallFrame.minY) * expansion,
      width: smallFrame.width + (fullFrame.width - smallFrame.width) * expansion,
      height: max(1, smallFrame.height + (fullFrame.height - smallFrame.height) * expansion))
    var coverFrame: CGRect?
    if tracking, !presenting {
      // In the reference's drag phase the page and cover translate together;
      // the cover does not start shrinking until the finger is released.
      frame = fullFrame.offsetBy(dx: 0, dy: current * fullFrame.height)
      coverFrame = startFrame.offsetBy(dx: 0, dy: current * fullFrame.height)
    } else if let destination, let settleSurfaceFrame, let settleCoverFrame {
      let distance = destination - settleStartProgress
      let p = abs(distance) > 0.0001 ? min(1, max(0, (transition - settleStartProgress) / distance)) : 1
      func interpolate(_ from: CGRect, _ to: CGRect) -> CGRect {
        CGRect(x: from.minX + (to.minX-from.minX)*p, y: from.minY + (to.minY-from.minY)*p,
          width: from.width + (to.width-from.width)*p, height: from.height + (to.height-from.height)*p)
      }
      let finishesExpanded = presenting == (destination == 1)
      frame = interpolate(settleSurfaceFrame, finishesExpanded ? fullFrame : smallFrame)
      coverFrame = interpolate(settleCoverFrame, destination == 1 ? endFrame : startFrame)
      if !presenting, destination == 1 {
        // Measured 4.97–5.30s: the shrinking cover travels down past the
        // capsule before settling into it. Keep this path separate from scale.
        let positions: [CGFloat] = [0, 0.108, 0.317, 0.527, 0.683, 0.792, 0.880, 0.919, 0.962, 1]
        let offsets: [CGFloat] = [0, 0.063, 0.096, 0.108, 0.105, 0.098, 0.078, 0.062, 0.043, 0]
        if let i = positions.indices.dropFirst().first(where: { p <= positions[$0] }) {
          let t = (p-positions[i-1]) / (positions[i]-positions[i-1])
          coverFrame?.origin.y += fullFrame.height * (offsets[i-1] + (offsets[i]-offsets[i-1])*t)
        }
      }
    }
    renderedSurfaceFrame = frame
    let scale = max(0.01, frame.width / fullFrame.width)
    let clampedExpansion = min(1, max(0, expansion))
    let visualExpansion = manualDismissOpacity ?
      min(1, max(0, (frame.height-smallFrame.height)/(fullFrame.height-smallFrame.height))) : clampedExpansion
    let cardRadius = min(56, fullFrame.width * 0.14)
    let radius = (smallFrame.height / 2 + (cardRadius-smallFrame.height/2)*clampedExpansion) *
      min(1, max(0, (1-clampedExpansion)/0.015))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    UIView.performWithoutAnimation {
      // The live glass capsule and its title/buttons emerge on the same clock
      // as the collapsing surface. Reversing a drag reverses this handoff too.
      let handoff = min(1, max(0, visualExpansion / 0.22))
      let settling = min(1, max(-0.2, visualExpansion / 0.22))
      miniPlayer?.alpha = miniAlpha * (1 - handoff)
      miniPlayer?.transform = miniTransform
        .translatedBy(x: 0, y: 8 * settling)
        .scaledBy(x: 1 - 0.06 * settling, y: 1 - 0.12 * settling)
      func smooth(_ value: CGFloat) -> CGFloat {
        let v = min(1, max(0, value))
        return v*v*(3-2*v)
      }
      if manualDismissOpacity {
        let closing = 1-visualExpansion
        player.alpha = 1-smooth((closing-0.78)/0.22)
        contentMasks.forEach { $0.alpha = 1-smooth((closing-0.35)/0.30) }
      }
      let colorProgress = smooth((visualExpansion-0.1)/0.8)
      glass.frame = frame
      glass.layer.cornerRadius = radius
      glass.alpha = 1-colorProgress
      palette.alpha = paletteAlpha * colorProgress
      backdrop.alpha = 0.16 * clampedExpansion
      capsuleHeader.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: smallFrame.height)
      capsuleHeader.alpha = tracking && !presenting ? 0 :
        smooth(visualExpansion/0.07) * (1-smooth(visualExpansion/0.75))
      // Carry the content with the card's top edge, instead of uncovering a
      // bottom-anchored full-height page like a vertical curtain.
      player.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
        tx: frame.midX - fullFrame.midX,
        ty: frame.minY - (fullFrame.midY - fullFrame.height * scale / 2))
      surface.frame = CGRect(x: (player.bounds.width - frame.width / scale) / 2,
                             y: 0,
                             width: frame.width / scale, height: frame.height / scale)
      surface.layer.cornerRadius = radius / scale
      if let cover {
        let p = progress
        cover.frame = coverFrame ?? CGRect(
          x: startFrame.minX + (endFrame.minX - startFrame.minX) * p,
          y: startFrame.minY + (endFrame.minY - startFrame.minY) * p,
          width: startFrame.width + (endFrame.width - startFrame.width) * p,
          height: startFrame.height + (endFrame.height - startFrame.height) * p)
        cover.layer.cornerRadius = startRadius + (endRadius - startRadius) * p
        if let coverShadow, let fullArtworkShadow {
          // The real shadow is masked with the real cover. Carry a matching
          // shadow with the flying cover, including paused scaling and reversal.
          let fullCoverFrame = presenting ? endFrame : startFrame
          let fullScale = fullCoverFrame.width / max(1, fullArtworkShadow.bounds.width)
          let coverScale = cover.bounds.width / max(1, fullCoverFrame.width)
          let visibility = presenting ? p : 1 - p
          let layer = fullArtworkShadow.layer.presentation() ?? fullArtworkShadow.layer
          coverShadow.frame = cover.frame
          coverShadow.layer.shadowColor = layer.shadowColor
          coverShadow.layer.shadowOpacity = layer.shadowOpacity * Float(visibility)
          coverShadow.layer.shadowRadius = layer.shadowRadius * fullScale * coverScale
          coverShadow.layer.shadowOffset = CGSize(
            width: layer.shadowOffset.width * fullScale * coverScale,
            height: layer.shadowOffset.height * fullScale * coverScale)
          var shadowTransform = CGAffineTransform(scaleX: fullScale * coverScale, y: fullScale * coverScale)
          coverShadow.layer.shadowPath = layer.shadowPath?.copy(using: &shadowTransform)
        }
        let fullArtwork = presenting ? endFrame : startFrame
        let projectedArtworkBottom = player.frame.minY + (fullArtwork.maxY - fullFrame.minY) * scale
        let offset = (cover.frame.maxY - projectedArtworkBottom) / scale
        // Preserve the final gap below the flying cover. The controls follow
        // the metadata, rather than appearing behind the cover halfway through.
        for content in foreground {
          content.view.transform = content.transform.translatedBy(x: 0, y: offset)
        }
      }
      if let handle {
        let fullCenter = handle.center.y
        let inset = smallFrame.height / 2 + (fullCenter - smallFrame.height / 2) * expansion
        let offset = (frame.minY + inset - player.frame.minY) / scale - fullCenter
        handle.transform = handleTransform.translatedBy(x: 0, y: offset)
      }
    }
    CATransaction.commit()
  }

  func settle(to target: CGFloat) {
    guard destination == nil else { return }
    settleStartProgress = tracking ? trackingProgress : 0
    settleSurfaceFrame = renderedSurfaceFrame
    settleCoverFrame = cover?.frame ?? .zero
    tracking = false
    destination = target
  }

  @objc private func tick(_ link: CADisplayLink) {
    sample()
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
    for content in foreground { content.view.transform = content.transform }
    handle?.transform = handleTransform
    miniPlayer?.transform = miniTransform
    miniPlayer?.alpha = miniAlpha
    palette.alpha = paletteAlpha
    glass.removeFromSuperview()
    backdrop.removeFromSuperview()
    capsuleHeader.removeFromSuperview()
  }
}

@MainActor
final class PlayerSurfaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  static var springDamping: CGFloat { 1 }
  private let isPresenting: Bool
  private weak var sourcePlayer: UIView?
  private weak var sourceArtwork: UIImageView?
  private var animator: UIViewPropertyAnimator?

  init(isPresenting: Bool, sourcePlayer: UIView?, sourceArtwork: UIImageView?) {
    self.isPresenting = isPresenting
    self.sourcePlayer = sourcePlayer
    self.sourceArtwork = sourceArtwork
  }

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.15 : (isPresenting ? 0.60 : 0.50)
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    interruptibleAnimator(using: context).startAnimation()
  }

  func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
    if let animator { return animator }
    let duration = transitionDuration(using: context)
    let container = context.containerView
    guard let fromVC = context.viewController(forKey: .from),
          let toVC = context.viewController(forKey: .to),
          let popup = (isPresenting ? toVC : fromVC) as? PopupPlayerVC,
          let fromView = context.view(forKey: .from),
          let toView = context.view(forKey: .to) else {
      context.completeTransition(false)
      return UIViewPropertyAnimator(duration: 0, curve: .linear)
    }
    if isPresenting {
      toView.frame = context.finalFrame(for: toVC)
      container.addSubview(toView)
      popup.changeDisplayStyleVisually(to: popup.appDelegate.storage.settings.user.playerDisplayStyle,
                                       animated: false)
    } else {
      toView.frame = context.finalFrame(for: toVC)
      container.insertSubview(toView, belowSubview: fromView)
    }
    toView.layoutIfNeeded()
    popup.view.layoutIfNeeded()
    popup.largeCurrentlyPlayingView?.layoutIfNeeded()
    let playerView = popup.view!
    let fullFrame = isPresenting ? context.finalFrame(for: toVC) : playerView.frame
    let smallFrame = sourcePlayer.map { $0.convert($0.bounds, to: container) } ??
      CGRect(x: fullFrame.minX + 20, y: fullFrame.maxY - 140, width: fullFrame.width - 40, height: 56)
    let reducedMotion = UIAccessibility.isReduceMotionEnabled
    let originalMask = playerView.mask
    let originalAlpha = playerView.alpha
    let originalTransform = playerView.transform
    let originalBackground = playerView.backgroundColor
    let targetArtwork = popup.transitionArtwork
    let artworkShadow = popup.largeCurrentlyPlayingView?.transitionArtworkShadow
    let smallArtworkFrame = sourceArtwork.map { $0.convert($0.bounds, to: container) }
    let largeArtworkFrame = targetArtwork.map { $0.convert($0.bounds, to: container) }
    // A newly loaded destination may still be decoding its full-size image.
    // Start with the cover the user can already see, never its placeholder.
    let artworkImage = isPresenting ? (sourceArtwork?.image ?? targetArtwork?.image) :
      (targetArtwork?.image ?? sourceArtwork?.image)
    // UIKit owns the spring/interactive timeline. A transparent timing probe
    // lets one display update apply the surface and artwork geometry together.
    let progressView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    progressView.alpha = 0
    progressView.isUserInteractionEnabled = false
    container.addSubview(progressView)
    let surface = UIView(frame: playerView.bounds)
    surface.accessibilityIdentifier = "player-transition-surface"
    surface.backgroundColor = .black
    surface.layer.cornerCurve = .continuous
    playerView.mask = surface
    playerView.alpha = isPresenting ? 0 : originalAlpha
    // Refresh and appearance callbacks legitimately write artwork/control alpha.
    // A separate mask belongs to this transition and cannot be reset by them.
    var maskedViews = [(view: UIView, original: UIView?)]()
    func installMask(on view: UIView, alpha: CGFloat, identifier: String) -> UIView {
      maskedViews.append((view, view.mask))
      let mask = UIView(frame: view.bounds)
      mask.backgroundColor = .black
      mask.alpha = alpha
      mask.accessibilityIdentifier = identifier
      view.mask = mask
      return mask
    }
    var contentMasks = [UIView]()
    if !reducedMotion {
      // Keep the foreground visible through the spring's main travel/rebound.
      // Hide it only near the capsule, where full-size controls cannot fit.
      for content in playerView.subviews where content !== popup.backgroundImage {
        contentMasks.append(installMask(on: content, alpha: isPresenting ? 0 : 1,
                                        identifier: "player-transition-content-mask"))
      }
    }
    var flyingArtwork: UIImageView?
    var flyingShadow: UIView?
    let backdrop = UIView(frame: container.bounds)
    backdrop.backgroundColor = .black
    backdrop.isUserInteractionEnabled = false
    let glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    glass.isUserInteractionEnabled = false
    glass.clipsToBounds = true
    glass.layer.cornerCurve = .continuous
    let capsuleHeader = PlayerTransitionCapsuleHeader(player: popup.player)
    if !reducedMotion {
      container.insertSubview(backdrop, belowSubview: playerView)
      container.insertSubview(glass, belowSubview: playerView)
      container.addSubview(capsuleHeader)
      playerView.backgroundColor = .clear
    }
    if !reducedMotion, let sourceArtwork, let targetArtwork,
       let smallArtworkFrame, let largeArtworkFrame,
       let image = artworkImage {
      let cover = UIImageView(image: image)
      cover.accessibilityIdentifier = "player-surface-transition-artwork"
      cover.contentMode = .scaleAspectFit
      cover.clipsToBounds = true
      cover.layer.cornerCurve = .continuous
      cover.frame = isPresenting ? smallArtworkFrame : largeArtworkFrame
      cover.layer.cornerRadius = isPresenting ? sourceArtwork.layer.cornerRadius : targetArtwork.layer.cornerRadius
      if let artworkShadow, !artworkShadow.isHidden {
        let shadow = UIView(frame: cover.frame)
        shadow.isUserInteractionEnabled = false
        shadow.accessibilityIdentifier = "player-surface-transition-shadow"
        container.addSubview(shadow)
        flyingShadow = shadow
      }
      container.addSubview(cover)
      flyingArtwork = cover
      for artwork in [sourceArtwork, targetArtwork, artworkShadow].compactMap({ $0 }) {
        _ = installMask(on: artwork, alpha: 0, identifier: "player-transition-artwork-mask")
      }
    }
    if !reducedMotion {
      let motion = PlayerArtworkMotion(player: playerView, surface: surface, progressView: progressView,
        smallFrame: smallFrame, fullFrame: fullFrame, presenting: isPresenting,
        cover: flyingArtwork, coverShadow: flyingShadow, fullArtworkShadow: artworkShadow,
        endFrame: (isPresenting ? largeArtworkFrame : smallArtworkFrame) ?? .zero,
        endRadius: (isPresenting ? targetArtwork?.layer.cornerRadius : sourceArtwork?.layer.cornerRadius) ?? 0,
        foreground: [popup.largePlayerPlaceholderView, popup.tableView, popup.controlPlaceholderView,
                     popup.queueModeBackgrounds].compactMap { $0 },
        handle: playerView.subviews.first(where: { $0 is UIButton }), miniPlayer: sourcePlayer,
        interactive: context.isInteractive, glass: glass, backdrop: backdrop,
        palette: popup.backgroundImage, capsuleHeader: capsuleHeader, contentMasks: contentMasks)
      popup.surfaceTransition.artworkMotion = motion
      if let destination = popup.surfaceTransition.artworkDestination {
        motion.settle(to: destination)
      } else if !context.isInteractive {
        motion.settle(to: 1)
      }
    }
    let animator = UIViewPropertyAnimator(duration: duration,
      timingParameters: UISpringTimingParameters(mass: 1, stiffness: 338.56, damping: 36.8, initialVelocity: .zero))
    animator.addAnimations { [contentMasks] in
      progressView.transform = CGAffineTransform(translationX: 1, y: 0)
      if reducedMotion {
        playerView.alpha = self.isPresenting ? originalAlpha : 0
      } else if !(context.isInteractive && !self.isPresenting) {
        UIView.animateKeyframes(withDuration: duration, delay: 0,
                                options: [.calculationModeLinear]) {
          UIView.addKeyframe(withRelativeStartTime: self.isPresenting ? 0.05 : 0.35,
                            relativeDuration: 0.30) {
            contentMasks.forEach { $0.alpha = self.isPresenting ? 1 : 0 }
          }
          // UIKit owns opacity while the display link owns geometry. Updating
          // root-view alpha directly during an interactive UIKit transition can
          // leave its presentation opacity behind the rendered surface.
          UIView.addKeyframe(withRelativeStartTime: self.isPresenting ? 0 : 0.78,
                            relativeDuration: self.isPresenting ? 0.035 : 0.22) {
            playerView.alpha = self.isPresenting ? originalAlpha : 0
          }
        }
      }
    }
    animator.scrubsLinearly = true
    let presenting = isPresenting
    animator.addCompletion { [weak self, maskedViews, flyingArtwork, flyingShadow] _ in
      let completed = !context.transitionWasCancelled
      // Restore nested artwork masks before their ancestor content masks.
      for entry in maskedViews.reversed() { entry.view.mask = entry.original }
      playerView.mask = originalMask
      playerView.alpha = originalAlpha
      playerView.transform = originalTransform
      playerView.backgroundColor = originalBackground
      if presenting != completed { playerView.removeFromSuperview() }
      flyingArtwork?.removeFromSuperview()
      flyingShadow?.removeFromSuperview()
      progressView.removeFromSuperview()
      popup.surfaceTransition.artworkMotion?.stop()
      popup.surfaceTransition.artworkMotion = nil
      popup.surfaceTransition.artworkProgress = 0
      popup.surfaceTransition.artworkDestination = nil
      popup.surfaceTransition.presentationInteraction = nil
      popup.surfaceTransition.interaction = nil
      self?.animator = nil
      // Create fresh native backdrops after the transition masks are gone.
      popup.rebuildQueueModeBackgrounds()
      context.completeTransition(completed)
    }
    self.animator = animator
    return animator
  }
}

extension PopupPlayerVC {
  static let displaStyleAnimationDuration = TimeInterval(0.2)

  func switchDisplayStyleOptionPersistent() {
    appDelegate.userStatistics.usedAction(.changePlayerDisplayStyle)
    var displayStyle = appDelegate.storage.settings.user.playerDisplayStyle
    displayStyle.switchToNextStyle()
    if displayStyle == .compact {
      // Queue and lyrics are mutually exclusive pages, not stacked overlays.
      appDelegate.storage.settings.user.isPlayerLyricsDisplayed = false
      appDelegate.storage.settings.user.isPlayerVisualizerDisplayed = false
    }
    appDelegate.storage.settings.user.playerDisplayStyle = displayStyle
    changeDisplayStyleVisually(to: displayStyle, animated: true)
  }

  func changeDisplayStyleVisually(to displayStyle: PlayerDisplayStyle, animated: Bool = true) {
    guard let largeView = largeCurrentlyPlayingView else { return }
    largeView.finishDisplayAnimation()
    let headerWasVisible = !largeView.compactHeader.isHidden
    let sourceArtwork = largeView.transitionArtwork
    let sourceFrame = sourceArtwork.convert(sourceArtwork.bounds, to: view)
    lyricsModeDidChange()

    if displayStyle == .large {
      largeView.display(element: largeView.getDisplayElementBasedOnConfig(), animated: false)
    } else {
      scrollToCurrentlyPlayingRow()
    }
    largeView.updateCompactHeaderVisibility()
    view.layoutIfNeeded()
    let targetArtwork = largeView.transitionArtwork
    let headerIsVisible = !largeView.compactHeader.isHidden
    let outgoing: UIView = displayStyle == .compact ? largePlayerPlaceholderView : tableView
    let incoming: UIView = displayStyle == .compact ? tableView : largePlayerPlaceholderView
    outgoing.layer.removeAllAnimations()
    incoming.layer.removeAllAnimations()

    guard animated, !UIAccessibility.isReduceMotionEnabled else {
      outgoing.alpha = 0
      outgoing.isHidden = true
      incoming.alpha = 1
      incoming.isHidden = false
      updateQueueModeBackgrounds()
      return
    }

    // Lyrics <-> queue keeps the exact same header views on screen, untouched.
    // Only transitions to/from the large cover animate artwork geometry.
    if !(headerWasVisible && headerIsVisible) {
      animateArtwork(
        image: sourceArtwork.image,
        sourceView: sourceArtwork,
        targetView: targetArtwork,
        sourceFrame: sourceFrame,
        targetFrame: targetArtwork.convert(targetArtwork.bounds, to: view)
      )
    }
    outgoing.isHidden = false
    incoming.isHidden = false
    updateQueueModeBackgrounds()
    UIView.animate(withDuration: Self.displaStyleAnimationDuration, delay: 0,
                   options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
      outgoing.alpha = 0
      incoming.alpha = 1
      self.queueModeBackgrounds?.alpha = self.tableView.alpha
    } completion: { [weak self] finished in
      guard finished else { return }
      self?.rebuildQueueModeBackgrounds()
    }
  }

  private func animateArtwork(
    image: UIImage?,
    sourceView: UIView,
    targetView: UIView,
    sourceFrame: CGRect,
    targetFrame: CGRect
  ) {
    // 3. Create a replica of the artwork
    let fakeImageView = RoundedImage(frame: sourceFrame)
    fakeImageView.accessibilityIdentifier = "player-layout-transition-artwork"
    fakeImageView.backgroundColor = .clear
    fakeImageView.image = image
    fakeImageView.contentMode = .scaleAspectFit
    fakeImageView.clipsToBounds = true
    fakeImageView.alpha = sourceView.alpha

    // animate alpha for active lyrics view
    UIView.animate(withDuration: Self.displaStyleAnimationDuration, delay: 0, animations: {
      fakeImageView.alpha = targetView.alpha
    }, completion: { _ in
      fakeImageView.alpha = targetView.alpha
    })

    animatePlayStyleObject(
      object: fakeImageView,
      sourceView: sourceView,
      targetView: targetView,
      sourceFrame: sourceFrame,
      targetFrame: targetFrame
    )
  }

  private func animatePlayStyleObject(
    object: UIView,
    sourceView: UIView,
    targetView: UIView,
    sourceFrame: CGRect,
    targetFrame: CGRect
  ) {
    sourceView.isHidden = true
    targetView.isHidden = true

    view.addSubview(object)

    UIView.animate(withDuration: Self.displaStyleAnimationDuration, delay: 0, animations: {
      object.frame = targetFrame
    }, completion: { _ in
      sourceView.isHidden = false
      targetView.isHidden = false
      object.removeFromSuperview()
    })
  }
}
