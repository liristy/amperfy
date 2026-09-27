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

// The same artwork travels between the mini player and the full-screen player.
// The destination is laid out once at its final size before measuring the cover.
@MainActor
final class PlayerArtworkTransitionDelegate: NSObject, UIViewControllerTransitioningDelegate {
  weak var sourceArtwork: UIImageView?
  var interaction: UIPercentDrivenInteractiveTransition?

  func animationController(forPresented presented: UIViewController,
                           presenting: UIViewController, source: UIViewController)
    -> UIViewControllerAnimatedTransitioning? {
    PlayerArtworkAnimator(isPresenting: true, sourceArtwork: sourceArtwork)
  }

  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    PlayerArtworkAnimator(isPresenting: false, sourceArtwork: sourceArtwork)
  }

  func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning)
    -> UIViewControllerInteractiveTransitioning? { interaction }
}

@MainActor
final class PlayerArtworkAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private let isPresenting: Bool
  private weak var sourceArtwork: UIImageView?

  init(isPresenting: Bool, sourceArtwork: UIImageView?) {
    self.isPresenting = isPresenting
    self.sourceArtwork = sourceArtwork
  }

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
    UIAccessibility.isReduceMotionEnabled ? 0.15 : 0.28
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    let container = context.containerView
    guard let fromVC = context.viewController(forKey: .from),
          let toVC = context.viewController(forKey: .to),
          let popup = (isPresenting ? toVC : fromVC) as? PopupPlayerVC,
          let fromView = context.view(forKey: .from),
          let toView = context.view(forKey: .to) else {
      context.completeTransition(false)
      return
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
    let fullArtwork = popup.transitionArtwork
    let smallFrame = sourceArtwork.map { $0.convert($0.bounds, to: container) }
    let largeFrame = fullArtwork.map { $0.convert($0.bounds, to: container) }
    let reducedMotion = UIAccessibility.isReduceMotionEnabled
    var movingArtwork: UIImageView?
    let sourceWasHidden = sourceArtwork?.isHidden ?? false
    let fullWasHidden = fullArtwork?.isHidden ?? false
    if !reducedMotion, let smallFrame, let largeFrame,
       smallFrame.width > 0, largeFrame.width > 0 {
      let image = UIImageView(image: fullArtwork?.image ?? sourceArtwork?.image)
      image.accessibilityIdentifier = "player-transition-artwork"
      image.contentMode = .scaleAspectFit
      image.clipsToBounds = true
      image.layer.cornerCurve = .continuous
      image.layer.cornerRadius = isPresenting ? 5 : 12
      image.frame = isPresenting ? smallFrame : largeFrame
      container.addSubview(image)
      movingArtwork = image
      sourceArtwork?.isHidden = true
      fullArtwork?.isHidden = true
    }
    let playerView = popup.view!
    if isPresenting {
      playerView.alpha = 0
      playerView.transform = reducedMotion ? .identity : CGAffineTransform(translationX: 0, y: 60)
    }
    UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                   options: [.curveEaseOut, .allowUserInteraction]) {
      playerView.alpha = self.isPresenting ? 1 : 0
      playerView.transform = self.isPresenting || reducedMotion ? .identity :
        CGAffineTransform(translationX: 0, y: container.bounds.height)
      if let smallFrame, let largeFrame {
        movingArtwork?.frame = self.isPresenting ? largeFrame : smallFrame
        movingArtwork?.layer.cornerRadius = self.isPresenting ? 12 : 5
      }
    } completion: { _ in
      let completed = !context.transitionWasCancelled
      movingArtwork?.removeFromSuperview()
      self.sourceArtwork?.isHidden = sourceWasHidden
      fullArtwork?.isHidden = fullWasHidden
      if !self.isPresenting, completed { playerView.removeFromSuperview() }
      playerView.alpha = 1
      playerView.transform = .identity
      context.completeTransition(completed)
    }
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
