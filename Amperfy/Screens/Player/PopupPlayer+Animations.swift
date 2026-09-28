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

// The complete player expands from, and contracts into, the mini-player capsule.
// Keep the live content at its final layout size inside a springing mask.
// Never swap a rendered screenshot for the real player at the end of the animation.
@MainActor
final class PlayerSurfaceTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
  weak var sourcePlayer: UIView?
  weak var sourceArtwork: UIImageView?
  var interaction: UIPercentDrivenInteractiveTransition?
  var presentationInteraction: UIPercentDrivenInteractiveTransition?

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

@MainActor
final class PlayerSurfaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  static var springDamping: CGFloat { UIAccessibility.isReduceMotionEnabled ? 1 : 0.62 }
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
    UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.78
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
    let targetArtwork = popup.transitionArtwork
    let artworkShadow = popup.largeCurrentlyPlayingView?.transitionArtworkShadow
    let smallArtworkFrame = sourceArtwork.map { $0.convert($0.bounds, to: container) }
    let largeArtworkFrame = targetArtwork.map { $0.convert($0.bounds, to: container) }
    // A newly loaded destination may still be decoding its full-size image.
    // Start with the cover the user can already see, never its placeholder.
    let artworkImage = isPresenting ? (sourceArtwork?.image ?? targetArtwork?.image) :
      (targetArtwork?.image ?? sourceArtwork?.image)
    // Move the content with the growing surface, so the rebound is visible in
    // the whole page rather than only in a mask outside the screen edges.
    let collapsedTransform = reducedMotion ? originalTransform : originalTransform
      .translatedBy(x: 0, y: playerView.bounds.height * 0.12)
      .scaledBy(x: 0.72, y: 0.72)
    // Measure the capsule in the collapsed coordinate space so the live view's
    // elastic scale still lands precisely on the mini player in either direction.
    playerView.transform = collapsedTransform
    let localSmallFrame = playerView.convert(smallFrame, from: container)
    playerView.transform = isPresenting ? collapsedTransform : originalTransform
    let surface = UIView(frame: isPresenting && !reducedMotion ? localSmallFrame : playerView.bounds)
    surface.accessibilityIdentifier = "player-transition-surface"
    surface.backgroundColor = .black
    surface.layer.cornerCurve = .continuous
    surface.layer.cornerRadius = isPresenting && !reducedMotion ? localSmallFrame.height / 2 : 0
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
    var contentTransforms = [(view: UIView, original: CGAffineTransform)]()
    if !reducedMotion {
      // Keep the foreground visible through the spring's main travel/rebound.
      // Hide it only near the capsule, where full-size controls cannot fit.
      for content in playerView.subviews where content !== popup.backgroundImage {
        contentTransforms.append((content, content.transform))
        if isPresenting {
          content.transform = content.transform.translatedBy(x: 0, y: playerView.bounds.height * 0.35)
        }
        contentMasks.append(installMask(on: content, alpha: isPresenting ? 0 : 1,
                                        identifier: "player-transition-content-mask"))
      }
    }
    var flyingArtwork: UIImageView?
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
      container.addSubview(cover)
      flyingArtwork = cover
      for artwork in [sourceArtwork, targetArtwork, artworkShadow].compactMap({ $0 }) {
        _ = installMask(on: artwork, alpha: 0, identifier: "player-transition-artwork-mask")
      }
    }
    let animator = UIViewPropertyAnimator(
      duration: duration, dampingRatio: Self.springDamping
    ) { [contentMasks, contentTransforms, flyingArtwork] in
      playerView.transform = self.isPresenting ? originalTransform : collapsedTransform
      for entry in contentTransforms {
        entry.view.transform = self.isPresenting ? entry.original :
          entry.original.translatedBy(x: 0, y: playerView.bounds.height * 0.35)
      }
      surface.frame = self.isPresenting || reducedMotion ? playerView.bounds : localSmallFrame
      surface.layer.cornerRadius = self.isPresenting || reducedMotion ? 0 : localSmallFrame.height / 2
      if reducedMotion {
        playerView.alpha = self.isPresenting ? originalAlpha : 0
      } else {
        UIView.animateKeyframes(withDuration: duration, delay: 0,
                                options: [.calculationModeLinear]) {
          UIView.addKeyframe(withRelativeStartTime: self.isPresenting ? 0.05 : 0.35,
                            relativeDuration: 0.30) {
            contentMasks.forEach { $0.alpha = self.isPresenting ? 1 : 0 }
          }
          // The moving surface must remain opaque through the entire visible
          // morph. Crossfade only at the capsule endpoint; fading the page over
          // its travel turns the whole-player spring into a cover-only animation.
          // Keep the real mini player underneath, never a stale glass snapshot.
          UIView.addKeyframe(withRelativeStartTime: self.isPresenting ? 0 : 0.965,
                            relativeDuration: 0.035) {
            playerView.alpha = self.isPresenting ? originalAlpha : 0
          }
        }
      }
      if let smallArtworkFrame, let largeArtworkFrame {
        // Share the interactive timeline, but explicitly replace the inherited
        // spring: the cover travels smoothly while only the whole page rebounds.
        UIView.animate(withDuration: duration, delay: 0,
                       options: [.overrideInheritedOptions, .overrideInheritedCurve, .curveEaseInOut]) {
          flyingArtwork?.frame = self.isPresenting ? largeArtworkFrame : smallArtworkFrame
          flyingArtwork?.layer.cornerRadius = self.isPresenting ? (targetArtwork?.layer.cornerRadius ?? 0) :
            (self.sourceArtwork?.layer.cornerRadius ?? 0)
        }
      }
    }
    animator.scrubsLinearly = true
    let presenting = isPresenting
    animator.addCompletion { [weak self, maskedViews, contentTransforms, flyingArtwork] _ in
      let completed = !context.transitionWasCancelled
      // Restore nested artwork masks before their ancestor content masks.
      for entry in maskedViews.reversed() { entry.view.mask = entry.original }
      playerView.mask = originalMask
      playerView.alpha = originalAlpha
      playerView.transform = originalTransform
      for entry in contentTransforms { entry.view.transform = entry.original }
      if presenting != completed { playerView.removeFromSuperview() }
      flyingArtwork?.removeFromSuperview()
      popup.surfaceTransition.presentationInteraction = nil
      popup.surfaceTransition.interaction = nil
      self?.animator = nil
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
    UIView.animate(withDuration: Self.displaStyleAnimationDuration, delay: 0,
                   options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]) {
      outgoing.alpha = 0
      incoming.alpha = 1
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
