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
// Keep the full-screen content laid out at its final size inside a springing mask.
@MainActor
final class PlayerSurfaceTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
  weak var sourcePlayer: UIView?
  var interaction: UIPercentDrivenInteractiveTransition?
  var presentationInteraction: UIPercentDrivenInteractiveTransition?

  func interactionControllerForPresentation(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning? { presentationInteraction }

  func animationController(forPresented presented: UIViewController,
                           presenting: UIViewController, source: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
    PlayerSurfaceAnimator(isPresenting: true, sourcePlayer: sourcePlayer)
  }

  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    PlayerSurfaceAnimator(isPresenting: false, sourcePlayer: sourcePlayer)
  }

  func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning? { interaction }
}

@MainActor
final class PlayerSurfaceAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private let isPresenting: Bool
  private weak var sourcePlayer: UIView?
  private var animator: UIViewPropertyAnimator?

  init(isPresenting: Bool, sourcePlayer: UIView?) {
    self.isPresenting = isPresenting
    self.sourcePlayer = sourcePlayer
  }

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.6
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    interruptibleAnimator(using: context).startAnimation()
  }

  func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
    if let animator { return animator }
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
    let sourceOpacity = sourcePlayer?.layer.opacity ?? 1
    let playerOpacity = playerView.layer.opacity
    let capsule = sourcePlayer?.snapshotView(afterScreenUpdates: true)
    let movingPlayer = playerView.snapshotView(afterScreenUpdates: true) ?? UIView(frame: playerView.bounds)
    movingPlayer.accessibilityIdentifier = "player-transition-content"
    let surface = UIView(frame: isPresenting && !reducedMotion ? smallFrame : fullFrame)
    surface.accessibilityIdentifier = "player-transition-surface"
    surface.backgroundColor = .secondarySystemBackground
    surface.clipsToBounds = true
    surface.autoresizesSubviews = false
    surface.layer.cornerCurve = .continuous
    surface.layer.cornerRadius = isPresenting && !reducedMotion ? smallFrame.height / 2 : 0
    container.addSubview(surface)
    surface.addSubview(movingPlayer)
    movingPlayer.bounds = CGRect(origin: .zero, size: fullFrame.size)
    movingPlayer.center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
    movingPlayer.transform = isPresenting && !reducedMotion ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
    movingPlayer.alpha = isPresenting ? 0 : 1
    if let capsule, !reducedMotion {
      capsule.bounds = CGRect(origin: .zero, size: smallFrame.size)
      capsule.center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
      capsule.alpha = isPresenting ? 1 : 0
      surface.addSubview(capsule)
    }
    // Keep the real views attached and interactive so an in-flight pan is not
    // cancelled, and safe-area changes cannot relayout the player mid-morph.
    sourcePlayer?.layer.opacity = 0
    playerView.layer.opacity = 0
    let animator = UIViewPropertyAnimator(
      duration: transitionDuration(using: context), dampingRatio: reducedMotion ? 1 : 0.74
    ) {
      movingPlayer.alpha = self.isPresenting ? 1 : 0
      surface.frame = self.isPresenting || reducedMotion ? fullFrame : smallFrame
      surface.layer.cornerRadius = self.isPresenting || reducedMotion ? 0 : smallFrame.height / 2
      movingPlayer.center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
      movingPlayer.transform = self.isPresenting || reducedMotion ? .identity : CGAffineTransform(scaleX: 0.92, y: 0.92)
      capsule?.center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
      capsule?.alpha = self.isPresenting ? 0 : 1
    }
    animator.scrubsLinearly = true
    let presenting = isPresenting
    animator.addCompletion { [weak self] _ in
      let completed = !context.transitionWasCancelled
      self?.sourcePlayer?.layer.opacity = sourceOpacity
      playerView.layer.opacity = playerOpacity
      if presenting != completed { playerView.removeFromSuperview() }
      surface.removeFromSuperview()
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
