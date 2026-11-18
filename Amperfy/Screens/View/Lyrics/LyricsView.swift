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
    static let duration = 0.58
    static let maximumDelay = 0.19
    static let totalDuration = duration + maximumDelay

    let start: CGFloat
    let target: CGFloat
    let focusedRow: Int
    let initialRowOffsets: [Int: CGFloat]
    let startTime = CACurrentMediaTime()

    func offset(after elapsed: CFTimeInterval, forRow row: Int? = nil) -> CGFloat {
      let distance = row.map { max(0, $0 - focusedRow) } ?? 0
      let delay = Self.maximumDelay * (1 - exp(-Double(distance) / 4))
      let fraction = min(1, max(0, (elapsed - delay) / Self.duration))
      let progress = CGFloat(1 - pow(1 - fraction, 4) * (1 + 4 * fraction))
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
  private var displayLink: CADisplayLink?
  private var scrollAnimation = true
  private var activeLinePosition: CGFloat = 0.26
  private var suppressAutoScrollUntil: Date?
  private let edgeMask = CAGradientLayer()
  private var previousSize: CGSize = .zero
  var playbackPosition: (() -> TimeInterval?)?
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
    if window == nil {
      if scrollTransition != nil { lastScrolledIndex = nil }
      stopScrollTransition()
      stopDisplayLink()
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
    if widthChanged {
      stopScrollTransition()
      lastScrolledIndex = nil
      reloadData()
    }
    if lastIndex == nil { setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false) }
  }

  private func updateContentInset() {
    // Keep the reading position fixed when the playback controls change the available height.
    let top = min(520, bounds.width) * activeLinePosition
    contentInset = UIEdgeInsets(top: top, left: 0,
                               bottom: max(0, bounds.height * 0.91 - top), right: 0)
  }

  public func display(lyrics source: StructuredLyrics, scrollAnimation: Bool, songTitle: String? = nil) {
    self.scrollAnimation = scrollAnimation
    let lyrics = source.lyricsForPlayback(songTitle: songTitle)
    // Playback notifications can repeat for the same song. Keep the reading position.
    if let current = self.lyrics, current.synced == lyrics.synced,
       current.offset == lyrics.offset, current.line == lyrics.line {
      return
    }
    stopScrollTransition()
    stopDisplayLink()
    self.lyrics = lyrics
    activeLinePosition = lyrics.line.contains { !$0.cues.isEmpty } ? 0.12 : 0.26
    updateContentInset()
    lyricModels = lyrics.line.enumerated().map { index, line in
      let nextStart = lyrics.line.dropFirst(index + 1).first?.start
      let model = LyricTableCellModel(lyric: line, nextLineStart: nextStart)
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
    stopDisplayLink()
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
    let lyric = lyricModels[indexPath.row].lyric
    return lyrics?.synced == true && !lyric.isInstrumentalLeadIn && lyric.start != nil
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let lyrics, lyrics.synced else { return }
    var lyric = lyricModels[indexPath.row].lyric
    guard !lyric.isInstrumentalLeadIn, let start = lyric.start else { return }
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
      let milliseconds = lyrics.adjustedTime(for: time).seconds * 1_000
      lyricModels[index].updateCues(at: milliseconds)
      if displayLink == nil, playbackPosition?() != nil { startDisplayLink() }
    }
    if index != lastIndex {
      lastIndex = index
      for (row, model) in lyricModels.enumerated() {
        model.updatePlaybackFocus(distance: index.map { abs(row - $0) })
      }
    }
    var readingRow = index
    if let index, lyricModels[index].lyric.isInstrumentalLeadIn, scrollAnimation,
       !UIAccessibility.isReduceMotionEnabled,
       (timeStep > 0 && timeStep <= 0.50) || lastScrolledIndex == index + 1 {
      let previewTime = CMTimeAdd(time, CMTime(value: 160, timescale: 1_000))
      if lyrics.activeLineIndex(at: previewTime) == index + 1 { readingRow = index + 1 }
    }
    guard let index = readingRow, index != lastScrolledIndex, !isDragging, !isDecelerating,
          suppressAutoScrollUntil.map({ Date() >= $0 }) ?? true else { return }
    layoutIfNeeded()
    let row = rectForRow(at: IndexPath(row: index, section: 0))
    let target = max(-contentInset.top, row.minY - contentInset.top)
    let animated = scrollAnimation && !UIAccessibility.isReduceMotionEnabled && lastScrolledIndex != nil
    let nextLine = lastScrolledIndex.map { index == $0 + 1 } ?? false
    if animated, nextLine, timeStep >= 0, timeStep <= 0.50, target > contentOffset.y, window != nil {
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
        if let cell = cell as? LyricTableCell, let index = indexPath(for: cell) {
          initialOffsets[index.row] = cell.scrollLift
        }
      }
    }
    scrollTransition = ScrollTransition(start: contentOffset.y, target: target, focusedRow: focusedRow,
                                        initialRowOffsets: initialOffsets)
    startDisplayLink()
  }

  private func startDisplayLink() {
    guard displayLink == nil, window != nil, !isHidden else { return }
    let link = CADisplayLink(target: self, selector: #selector(updateLyricsAnimation(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    displayLink = link
    link.add(to: .main, forMode: .common)
  }

  @objc private func updateLyricsAnimation(_ link: CADisplayLink) {
    guard UIApplication.shared.applicationState == .active, window != nil, !isHidden else {
      if scrollTransition != nil { lastScrolledIndex = nil }
      stopScrollTransition()
      stopDisplayLink()
      return
    }
    let hasWordTiming = lastIndex.map { !lyricModels[$0].lyric.cues.isEmpty } ?? false
    let position = hasWordTiming ? playbackPosition?() : nil
    let seconds = position.flatMap { $0.isFinite ? $0 : nil }
    if let seconds {
      scroll(toTime: CMTime(seconds: seconds, preferredTimescale: 10_000))
    }
    if let transition = scrollTransition {
      let elapsed = link.timestamp - transition.startTime
      let finished = elapsed >= ScrollTransition.totalDuration || UIAccessibility.isReduceMotionEnabled
      let offset = finished ? transition.target : transition.offset(after: elapsed)
      setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      layoutIfNeeded()
      // Hold each following lyric back by its own delay while the table follows the focused row.
      for cell in visibleCells {
        guard let cell = cell as? LyricTableCell, let index = indexPath(for: cell) else { continue }
        cell.scrollLift = finished ? 0 : offset - transition.offset(after: elapsed, forRow: index.row)
      }
      if finished { scrollTransition = nil }
    }
    if scrollTransition == nil, seconds == nil { stopDisplayLink() }
  }

  private func stopScrollTransition() {
    guard scrollTransition != nil else { return }
    scrollTransition = nil
    for cell in visibleCells {
      (cell as? LyricTableCell)?.scrollLift = 0
    }
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }
}
