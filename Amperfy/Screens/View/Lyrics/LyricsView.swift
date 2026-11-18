//
//  LyricsView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 17.06.24.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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
import CoreMedia
import Foundation
import UIKit

class LyricsView: UITableView, UITableViewDataSource, UITableViewDelegate {
  private struct ScrollTransition {
    static let duration = 0.45
    static let rowDelay = 0.04
    static let delayedRows = 4
    static let totalDuration = duration + rowDelay * Double(delayedRows)

    let start: CGFloat
    let target: CGFloat
    let focusedRow: Int
    let initialRowOffsets: [Int: CGFloat]
    let startTime = CACurrentMediaTime()

    func offset(after elapsed: CFTimeInterval, forRow row: Int? = nil) -> CGFloat {
      let delayedRow = row.map { min(max(0, $0 - focusedRow), Self.delayedRows) } ?? 0
      let delay = Double(delayedRow) * Self.rowDelay
      let fraction = min(1, max(0, (elapsed - delay) / Self.duration))
      let progress = CGFloat(1 - pow(1 - fraction, 3))
      let initialOffset = row.flatMap { initialRowOffsets[$0] } ?? 0
      let rowStart = start - initialOffset
      return rowStart + (target - rowStart) * progress
    }
  }

  private var lyrics: StructuredLyrics?
  private var lyricModels: [LyricTableCellModel] = []
  private var lastIndex: Int?
  private var lastScrolledIndex: Int?
  private var lastPlaybackTime: CMTime?
  private var scrollTransition: ScrollTransition?
  private var scrollDisplayLink: CADisplayLink?
  private var scrollAnimation = true
  private var activeLinePosition: CGFloat = 0.26
  private var suppressAutoScrollUntil: Date?
  private let edgeMask = CAGradientLayer()
  private var previousSize: CGSize = .zero
  public var onLyricSelected: ((LyricsLine) -> ())?
  public var onUpwardDrag: (() -> ())?
  public var onDownwardDrag: (() -> ())?

  override init(frame: CGRect, style: UITableView.Style) {
    super.init(frame: frame, style: style)
    commonInit()
  }

  public required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    commonInit()
  }

  private func commonInit() {
    register(LyricTableCell.self, forCellReuseIdentifier: LyricTableCell.typeName)
    separatorStyle = .none
    backgroundColor = .clear
    showsVerticalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    dataSource = self
    delegate = self
    edgeMask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor,
                       UIColor.white.cgColor, UIColor.clear.cgColor]
    edgeMask.locations = [0, 0.08, 0.90, 1]
    layer.mask = edgeMask
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil, scrollTransition != nil {
      stopScrollTransition()
      lastScrolledIndex = nil
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edgeMask.frame = bounds
    CATransaction.commit()
    guard bounds.size != previousSize else { return }
    let widthChanged = bounds.width != previousSize.width
    previousSize = bounds.size
    updateContentInset()
    // Only a width change affects line wrapping. Hiding the controls animates
    // height every frame; rebuilding all cells there interrupts highlighting.
    if widthChanged { reloadData() }
    lastScrolledIndex = nil
    if lastIndex == nil { setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false) }
  }

  private func updateContentInset() {
    contentInset = UIEdgeInsets(top: bounds.height * activeLinePosition, left: 0,
                               bottom: bounds.height * (0.91 - activeLinePosition), right: 0)
  }

  public func display(lyrics: StructuredLyrics, scrollAnimation: Bool) {
    self.scrollAnimation = scrollAnimation
    // Playback notifications can repeat for the same song. Keep the reading position.
    if let current = self.lyrics, current.synced == lyrics.synced,
       current.offset == lyrics.offset, current.line == lyrics.line {
      return
    }
    stopScrollTransition()
    self.lyrics = lyrics
    activeLinePosition = lyrics.line.contains { !$0.cues.isEmpty } ? 0.12 : 0.26
    updateContentInset()
    lyricModels = lyrics.line.map {
      let model = LyricTableCellModel(lyric: $0)
      model.isActiveLine = !lyrics.synced
      return model
    }
    lastIndex = nil
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    suppressAutoScrollUntil = nil
    reloadData()
    setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
  }

  public func highlightAllLyrics() { lyricModels.forEach { $0.isActiveLine = true } }

  public func clear() {
    stopScrollTransition()
    lyrics = nil
    lyricModels.removeAll()
    lastIndex = nil
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    reloadData()
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    lyricModels.count
  }

  public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    lyricModels[indexPath.row].calcHeight(containerWidth: bounds.width) + 30
  }

  public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = dequeueReusableCell(withIdentifier: LyricTableCell.typeName, for: indexPath) as! LyricTableCell
    cell.display(model: lyricModels[indexPath.row])
    return cell
  }

  public func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
    lyrics?.synced == true && lyricModels[indexPath.row].lyric.start != nil
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let lyrics, lyrics.synced else { return }
    var lyric = lyricModels[indexPath.row].lyric
    guard let start = lyric.start else { return }
    // OpenSubsonic's positive offset means the line appears earlier.
    lyric.start = max(0, start - lyrics.offset)
    stopScrollTransition()
    suppressAutoScrollUntil = nil
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    onLyricSelected?(lyric)
    scroll(toTime: lyric.startTime)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    stopScrollTransition()
    handleDrag(velocity: scrollView.panGestureRecognizer.velocity(in: scrollView))
    lastScrolledIndex = nil
    suppressAutoScrollUntil = Date().addingTimeInterval(5)
  }

  func handleDrag(velocity: CGPoint) {
    guard abs(velocity.y) > abs(velocity.x) else { return }
    if velocity.y < 0 { onUpwardDrag?() }
    else if velocity.y > 0 { onDownwardDrag?() }
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { suppressAutoScrollUntil = Date().addingTimeInterval(5) }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    suppressAutoScrollUntil = Date().addingTimeInterval(5)
  }

  func scroll(toTime time: CMTime) {
    guard let lyrics, lyrics.synced, !lyricModels.isEmpty else { return }
    let timeStep = lastPlaybackTime.map { CMTimeSubtract(time, $0).seconds } ?? 0
    lastPlaybackTime = time
    let index = lyrics.activeLineIndex(at: time)
    if let index, !lyricModels[index].lyric.cues.isEmpty {
      let adjustedTime = lyrics.adjustedTime(for: time)
      let milliseconds = CMTimeConvertScale(adjustedTime, timescale: 1_000,
                                            method: .roundTowardNegativeInfinity).value
      lyricModels[index].updateCues(at: milliseconds)
    }
    if index != lastIndex {
      if let lastIndex { lyricModels[lastIndex].isActiveLine = false }
      if let index { lyricModels[index].isActiveLine = true }
      lastIndex = index
    }
    guard let index, index != lastScrolledIndex, !isDragging, !isDecelerating,
          suppressAutoScrollUntil.map({ Date() >= $0 }) ?? true else { return }
    layoutIfNeeded()
    let row = rectForRow(at: IndexPath(row: index, section: 0))
    let target = max(-contentInset.top, row.minY - contentInset.top)
    let animated = scrollAnimation && !UIAccessibility.isReduceMotionEnabled && lastScrolledIndex != nil
    let nextLine = lastScrolledIndex.map { index == $0 + 1 } ?? false
    if animated, nextLine, timeStep > 0, timeStep <= 0.30, target > contentOffset.y, window != nil {
      startScrollTransition(to: target, focusedRow: index)
    } else {
      stopScrollTransition()
      setContentOffset(CGPoint(x: 0, y: target), animated: animated)
    }
    lastScrolledIndex = index
  }

  private func startScrollTransition(to target: CGFloat, focusedRow: Int) {
    var initialOffsets = [Int: CGFloat]()
    if scrollTransition != nil {
      for cell in visibleCells {
        if let index = indexPath(for: cell) {
          initialOffsets[index.row] = cell.contentView.transform.ty
        }
      }
    }
    scrollTransition = ScrollTransition(start: contentOffset.y, target: target, focusedRow: focusedRow,
                                        initialRowOffsets: initialOffsets)
    guard scrollDisplayLink == nil else { return }
    let displayLink = CADisplayLink(target: self, selector: #selector(updateScrollTransition(_:)))
    scrollDisplayLink = displayLink
    displayLink.add(to: .main, forMode: .common)
  }

  @objc private func updateScrollTransition(_ displayLink: CADisplayLink) {
    guard let transition = scrollTransition else { return }
    let elapsed = displayLink.timestamp - transition.startTime
    if elapsed >= ScrollTransition.totalDuration || UIAccessibility.isReduceMotionEnabled {
      setContentOffset(CGPoint(x: 0, y: transition.target), animated: false)
      stopScrollTransition()
      return
    }
    let offset = transition.offset(after: elapsed)
    setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    layoutIfNeeded()
    // Scroll the table with the focused row and hold each following row back by its delay.
    for cell in visibleCells {
      guard let index = indexPath(for: cell) else { continue }
      let rowOffset = transition.offset(after: elapsed, forRow: index.row)
      cell.contentView.transform = CGAffineTransform(translationX: 0, y: offset - rowOffset)
    }
  }

  private func stopScrollTransition() {
    guard let scrollDisplayLink else { return }
    scrollDisplayLink.invalidate()
    self.scrollDisplayLink = nil
    scrollTransition = nil
    for cell in visibleCells {
      cell.contentView.transform = .identity
    }
  }
}
