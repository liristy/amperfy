//
//  PopupPlayer+TableViewExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 08.02.24.
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

// MARK: - PlayerSectionCategory

enum PlayerSectionCategory: Int, CaseIterable {
  case contextPrev = 0
  case currentlyPlaying
  case userQueue
  case contextNext
}

// MARK: - PopupPlayerVC + UITableViewDataSource, UITableViewDelegate

extension PopupPlayerVC: UITableViewDataSource, UITableViewDelegate {
  func setupTableView() {
    // Visible headings are scroll-content subviews, outside UIKit's floating
    // section-header containers. Native headers only reserve transparent space.
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.register(nibName: CurrentlyPlayingTableCell.typeName)
    tableView.rowHeight = 56
    // All sizes are explicit; estimates would shift the card's scroll anchor.
    tableView.estimatedRowHeight = 0
    tableView.estimatedSectionHeaderHeight = 0
    tableView.estimatedSectionFooterHeight = 0
    tableView.backgroundColor = UIColor.clear
    tableView.backgroundView = nil
    // The full player already supplies a continuous artwork background.
    // A scroll-edge backdrop here creates a rectangular patch behind headers.
    tableView.topEdgeEffect.isHidden = true
    tableView.bottomEdgeEffect.isHidden = true
    tableView.isOpaque = false
    tableView.separatorStyle = .none
    tableView.sectionHeaderTopPadding = 0.0
  }

  func clearUserQueue() {
    guard player.userQueueCount > 0 else { return }
    tableView.beginUpdates()
    var indexPaths = [IndexPath]()
    for i in 0 ... player.userQueueCount - 1 {
      indexPaths.append(IndexPath(row: i, section: PlayerSectionCategory.userQueue.rawValue))
    }
    tableView.deleteRows(at: indexPaths, with: .fade)
    appDelegate.player.clearUserQueue()
    tableView.endUpdates()
    refreshUserQueueSectionHeader()
    tableView.layoutIfNeeded()
    refreshCellMasks()
  }

  func convertCellViewToPlayerIndex(cell: PlayableTableCell) -> PlayerIndex? {
    guard let indexPath = tableView.indexPath(for: cell),
          let playerIndex = PlayerIndex.create(from: indexPath) else { return nil }
    return playerIndex
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    PlayerSectionCategory.allCases.count
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    nil
  }

  func tableView(
    _ tableView: UITableView,
    willDisplayHeaderView view: UIView,
    forSection section: Int
  ) {
    view.backgroundColor = .clear
    view.isOpaque = false
    if let header = view as? UITableViewHeaderFooterView {
      header.backgroundConfiguration = .clear()
    }
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard self.tableView(tableView, heightForHeaderInSection: section) > 0.5 else { return nil }
    let spacer = UIView()
    spacer.backgroundColor = .clear
    spacer.isOpaque = false
    spacer.isUserInteractionEnabled = false
    return spacer
  }

  func layoutQueueSectionHeaders() {
    guard let player, tableView.numberOfSections == PlayerSectionCategory.allCases.count else { return }
    let headers: [(PlayerSectionCategory, UIView?, Bool)] = [
      (.contextPrev, contextPrevQueueSectionHeader, player.prevQueueCount > 0),
      (.userQueue, userQueueSectionHeader, player.userQueueCount > 0),
      (.contextNext, contextNextQueueSectionHeader, true),
    ]
    for (section, header, present) in headers {
      guard let header else { continue }
      guard present else {
        header.removeFromSuperview()
        continue
      }
      if header.superview !== tableView { tableView.addSubview(header) }
      header.frame = tableView.rectForHeader(inSection: section.rawValue)
      header.clipsToBounds = true
      header.setNeedsLayout()
      header.layoutIfNeeded()
      tableView.bringSubviewToFront(header)
    }
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    switch PlayerSectionCategory(rawValue: section) {
    case .contextPrev:
      return player.prevQueueCount > 0 ? ContextQueuePrevSectionHeader.frameHeight : .leastNormalMagnitude
    case .currentlyPlaying:
      return .leastNormalMagnitude
    case .userQueue:
      if player.userQueueCount == 0 {
        return CGFloat.leastNormalMagnitude
      } else {
        return UserQueueSectionHeader.frameHeight
      }
    case .contextNext:
      return ContextQueueNextSectionHeader.frameHeight
    case .none:
      return .leastNormalMagnitude
    }
  }

  func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    switch PlayerSectionCategory(rawValue: section) {
    case .contextNext, .contextPrev:
      return UIView()
    case .currentlyPlaying, .none, .userQueue:
      return nil
    }
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    switch PlayerSectionCategory(rawValue: section) {
    case .contextPrev: return player.prevQueueCount > 0 ? 16 : .leastNormalMagnitude
    case .currentlyPlaying, .none, .userQueue: return .leastNormalMagnitude
    case .contextNext: // calculate footer height to keep currently playing row on top of table view
      let heightOfContextNextRows = tableView.frame.height - ContextQueueNextSectionHeader.frameHeight - CurrentlyPlayingTableCell.rowHeight - 8
      let contextNextRowOccupiedHeight = CGFloat(player.nextQueueCount) * tableView.rowHeight
      let offset = heightOfContextNextRows - contextNextRowOccupiedHeight
      return offset > 0.0 ? offset : .leastNormalMagnitude
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch PlayerSectionCategory(rawValue: section) {
    case .contextPrev: return player.prevQueueCount
    case .currentlyPlaying: return 1
    case .userQueue: return player.userQueueCount
    case .contextNext: return player.nextQueueCount
    case .none: return 0
    }
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    let sectionCategors = PlayerSectionCategory(rawValue: indexPath.section)
    switch sectionCategors {
    case .contextNext, .contextPrev, .none, .userQueue:
      return tableView.rowHeight
    case .currentlyPlaying:
      return CurrentlyPlayingTableCell.rowHeight + 8
    }
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    switch PlayerSectionCategory(rawValue: indexPath.section) {
    case .contextNext, .contextPrev, .userQueue:
      let cell: PlayableTableCell = self.tableView.dequeueCell(for: tableView, at: indexPath)
      guard let playerIndex = PlayerIndex.create(from: indexPath),
            let playable = player.getPlayable(at: playerIndex)
      else { return cell }
      cell.display(
        playable: playable,
        playContextCb: { _ in PlayContext() },
        rootView: self,
        playerIndexCb: convertCellViewToPlayerIndex
      )
      cell.backgroundColor = UIColor.clear
      cell.maskCell(fromTop: 0.0)
      return cell
    case .currentlyPlaying:
      // History, the current song card and upcoming songs share one scroll surface.
      let marker = UITableViewCell(style: .default, reuseIdentifier: nil)
      marker.backgroundColor = .clear
      marker.backgroundConfiguration = .clear()
      marker.selectionStyle = .none
      if appDelegate.storage.settings.user.playerDisplayStyle == .compact {
        largeCurrentlyPlayingView?.attachCompactHeader(to: marker.contentView, anchor: marker.contentView)
      }
      return marker
    case .none:
      return UITableViewCell()
    }
  }

  // Override to allow editing only for certain rows
  func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
    switch PlayerSectionCategory(rawValue: indexPath.section) {
    case .contextNext, .contextPrev, .userQueue: return true
    case .currentlyPlaying, .none: return false
    }
  }

  // Override to support editing the table view.
  func tableView(
    _ tableView: UITableView,
    commit editingStyle: UITableViewCell.EditingStyle,
    forRowAt indexPath: IndexPath
  ) {
    if editingStyle == .delete {
      guard let playerIndex = PlayerIndex.create(from: indexPath) else { return }
      player.removePlayable(at: playerIndex)
      tableView.deleteRows(at: [indexPath], with: .fade)
      if PlayerSectionCategory(rawValue: indexPath.section) == .userQueue {
        refreshUserQueueSectionHeader()
      }
    }
  }

  // Override to support rearranging the table view.
  func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {
    refreshCellMasks()
    guard fromIndexPath != to,
          let fromPlayerIndex = PlayerIndex.create(from: fromIndexPath),
          let toPlayerIndex = PlayerIndex.create(from: to)
    else { return }
    player.movePlayable(from: fromPlayerIndex, to: toPlayerIndex)
    if PlayerSectionCategory(rawValue: fromIndexPath.section) == .userQueue ||
      PlayerSectionCategory(rawValue: to.section) == .userQueue {
      refreshUserQueueSectionHeader()
    }
  }

  // Override to deny movment of rows to specific sections
  func tableView(
    _ tableView: UITableView,
    targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
    toProposedIndexPath targetIndexPath: IndexPath
  )
    -> IndexPath {
    refreshCellMasks()
    // deny moving rows to currently playing section
    if PlayerSectionCategory(rawValue: targetIndexPath.section) == .currentlyPlaying {
      return sourceIndexPath
    } else {
      return targetIndexPath
    }
  }

  // Override to support conditional rearranging of the table view.
  func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
    // Return false if you do not want the item to be re-orderable.
    switch PlayerSectionCategory(rawValue: indexPath.section) {
    case .contextNext, .contextPrev, .userQueue: return true
    case .currentlyPlaying, .none: return false
    }
  }

  /// long press on cell animation (cell content gets smaller)
  private func makeTargetedPreview(
    for configuration: UIContextMenuConfiguration,
    willBeShown: Bool
  )
    -> UITargetedPreview? {
    guard let identifier = configuration.identifier as? String,
          let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
          let indexPath = tvPreviewInfo.indexPath,
          let cell = tableView.cellForRow(at: indexPath) as? PlayableTableCell
    else { return nil }

    let parameters = UIPreviewParameters()
    parameters.backgroundColor = .clear
    if willBeShown {
      cell.maskCell(fromTop: 0)
    } else {
      refreshCellMasks()
    }

    return UITargetedPreview(view: cell, parameters: parameters)
  }

  func tableView(
    _ tableView: UITableView,
    previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  )
    -> UITargetedPreview? {
    makeTargetedPreview(for: configuration, willBeShown: true)
  }

  func tableView(
    _ tableView: UITableView,
    previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
  )
    -> UITargetedPreview? {
    makeTargetedPreview(for: configuration, willBeShown: false)
  }

  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    guard let playerIndex = PlayerIndex.create(from: indexPath),
          let containable = player.getPlayable(at: playerIndex)
    else { return nil }
    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: containable.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: containable, on: self)
      return vc
    }) { suggestedActions in
      EntityPreviewActionBuilder(container: containable, on: self).createMenu()
    }
  }

  func tableView(
    _ tableView: UITableView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: self).performPreviewTransition()
      }
    }
  }
}

// MARK: - PopupPlayerVC + UITableViewDragDelegate

extension PopupPlayerVC: UITableViewDragDelegate {
  func tableView(
    _ tableView: UITableView,
    itemsForBeginning session: UIDragSession,
    at indexPath: IndexPath
  )
    -> [UIDragItem] {
    // Create empty DragItem -> we are using tableView(_:moveRowAt:to:) method
    [UIDragItem]()
  }

  func tableView(
    _ tableView: UITableView,
    dragPreviewParametersForRowAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters? {
    let parameter = UIDragPreviewParameters()
    parameter.backgroundColor = .clear
    return parameter
  }
}

// MARK: - PopupPlayerVC + UITableViewDropDelegate

extension PopupPlayerVC: UITableViewDropDelegate {
  func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
    false
  }

  func tableView(
    _ tableView: UITableView,
    performDropWith coordinator: UITableViewDropCoordinator
  ) {
    // Local drags with one item go through the existing tableView(_:moveRowAt:to:) method on the data source
  }

  func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {
    refreshCellMasks()
  }

  func tableView(
    _ tableView: UITableView,
    dropPreviewParametersForRowAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters? {
    refreshCellMasks()
    let parameter = UIDragPreviewParameters()
    parameter.backgroundColor = .clear
    return parameter
  }
}

extension PlayableTableCell {
  public func maskCell(fromTop margin: CGFloat) {
    if margin > 0 {
      layer.mask = visibilityMask(withLocation: margin / frame.size.height)
      layer.masksToBounds = true
    } else {
      layer.mask = nil
    }
  }

  private func visibilityMask(withLocation location: CGFloat) -> CAGradientLayer {
    let mask = CAGradientLayer()
    mask.frame = bounds
    mask.colors = [UIColor.white.withAlphaComponent(0).cgColor, UIColor.white.cgColor]
    let num = location as NSNumber
    mask.locations = [num, num]
    return mask
  }
}
