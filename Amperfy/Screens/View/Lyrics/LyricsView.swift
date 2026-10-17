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
  private var lyrics: StructuredLyrics?
  private var lyricModels: [LyricTableCellModel] = []
  private var lastIndex: Int?
  private var lastScrolledIndex: Int?
  private var scrollAnimation = true
  private var suppressAutoScrollUntil: Date?
  private var isFollowingPlayback = true {
    didSet {
      guard oldValue != isFollowingPlayback else { return }
      lyricModels.forEach { $0.isManuallyReading = !isFollowingPlayback }
    }
  }
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
    accessibilityIdentifier = "player.lyricsTable"
    edgeMask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor,
                       UIColor.white.cgColor, UIColor.clear.cgColor]
    edgeMask.locations = [0, 0.08, 0.90, 1]
    layer.mask = edgeMask
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
    contentInset = UIEdgeInsets(top: bounds.height * 0.26, left: 0,
                               bottom: bounds.height * 0.65, right: 0)
    // Only a width change affects line wrapping. Hiding the controls animates
    // height every frame; rebuilding all cells there interrupts highlighting.
    if widthChanged { reloadData() }
    lastScrolledIndex = nil
    if lastIndex == nil { setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false) }
  }

  public func display(lyrics: StructuredLyrics, scrollAnimation: Bool) {
    self.scrollAnimation = scrollAnimation
    // Playback notifications can repeat for the same song. Keep the reading position.
    if let current = self.lyrics, current.synced == lyrics.synced,
       current.offset == lyrics.offset, current.line.count == lyrics.line.count,
       zip(current.line, lyrics.line).allSatisfy({ $0.0.start == $0.1.start && $0.0.value == $0.1.value }) {
      return
    }
    self.lyrics = lyrics
    lyricModels = lyrics.line.map {
      let model = LyricTableCellModel(lyric: $0)
      model.isActiveLine = !lyrics.synced
      return model
    }
    lastIndex = nil
    lastScrolledIndex = nil
    suppressAutoScrollUntil = nil
    isFollowingPlayback = true
    reloadData()
    setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
  }

  public func highlightAllLyrics() { lyricModels.forEach { $0.isActiveLine = true } }

  public func clear() {
    lyrics = nil
    lyricModels.removeAll()
    lastIndex = nil
    lastScrolledIndex = nil
    isFollowingPlayback = true
    suppressAutoScrollUntil = nil
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
    lyrics?.synced == true && lyricModels[indexPath.row].lyric?.start != nil
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard let lyrics, lyrics.synced, var lyric = lyricModels[indexPath.row].lyric,
          let start = lyric.start else { return }
    tableView.deselectRow(at: indexPath, animated: false)
    // OpenSubsonic's positive offset means the line appears earlier.
    lyric.start = max(0, start - lyrics.offset)
    // Stop an older automatic scroll at its rendered position before centering
    // the selected line, rather than letting its animation pull the list back.
    let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
    setContentOffset(visibleOffset, animated: false)
    suppressAutoScrollUntil = nil
    isFollowingPlayback = true
    lastScrolledIndex = nil
    onLyricSelected?(lyric)
    scroll(toTime: lyric.startTime, forceFollow: true)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    isFollowingPlayback = false
    handleDrag(velocity: scrollView.panGestureRecognizer.velocity(in: scrollView))
    lastScrolledIndex = nil
    suppressAutoScrollUntil = Date().addingTimeInterval(5)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === panGestureRecognizer {
      let velocity = panGestureRecognizer.velocity(in: self)
      // Lyrics scrolling only owns vertical drags. Horizontal movement must
      // neither start a lyric drag nor invoke a track-changing gesture.
      guard abs(velocity.y) > abs(velocity.x) else { return false }
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  func handleDrag(velocity: CGPoint) {
    guard abs(velocity.y) > abs(velocity.x) else { return }
    if velocity.y < 0 { onUpwardDrag?() }
    else if velocity.y > 0 { onDownwardDrag?() }
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !isFollowingPlayback, !decelerate { suppressAutoScrollUntil = Date().addingTimeInterval(5) }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    if !isFollowingPlayback { suppressAutoScrollUntil = Date().addingTimeInterval(5) }
  }

  func scroll(toTime time: CMTime, forceFollow: Bool = false) {
    guard let lyrics, lyrics.synced, !lyricModels.isEmpty else { return }
    let index = lyrics.activeLineIndex(at: time)
    if index != lastIndex {
      if let lastIndex { lyricModels[lastIndex].isActiveLine = false }
      if let index { lyricModels[index].isActiveLine = true }
      lastIndex = index
    }
    guard forceFollow || (!isDragging && !isDecelerating &&
            (suppressAutoScrollUntil.map { Date() >= $0 } ?? true)) else { return }
    isFollowingPlayback = true
    suppressAutoScrollUntil = nil
    guard let index, forceFollow || index != lastScrolledIndex else { return }
    layoutIfNeeded()
    let row = rectForRow(at: IndexPath(row: index, section: 0))
    let target = max(-contentInset.top, row.minY - bounds.height * 0.26)
    let animated = !forceFollow && scrollAnimation && !UIAccessibility.isReduceMotionEnabled && lastScrolledIndex != nil
    setContentOffset(CGPoint(x: 0, y: target), animated: animated)
    lastScrolledIndex = index
  }
}

#if DEBUG && targetEnvironment(simulator)
  extension LyricsView {
    static func verifyMillisecondSelections() throws {
      for offset in [-100, 0, 100] {
        var lyrics = StructuredLyrics()
        lyrics.synced = true
        lyrics.offset = offset
        lyrics.line = (0..<30).map { $0 * 1001 }.map { start in
          var line = LyricsLine()
          line.start = start
          line.value = "Millisecond line \(start)"
          return line
        }
        let tracking = LyricsDecelerationSmokeView(frame: CGRect(x: 0, y: 0, width: 360, height: 480), style: .plain)
        let table: LyricsView = tracking
        table.display(lyrics: lyrics, scrollAnimation: true)
        var target: LyricsLine?
        table.onLyricSelected = { target = $0 }
        for row in [20, 1, 28, 0] {
          table.scrollViewWillBeginDragging(table)
          tracking.reportsDeceleration = true
          table.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
          table.tableView(table, didSelectRowAt: IndexPath(row: row, section: 0))
          // Ending callbacks from the interrupted drag must not undo the seek.
          table.scrollViewDidEndDragging(table, willDecelerate: false)
          table.scrollViewDidEndDecelerating(table)
          let expectedOffset = table.rectForRow(at: IndexPath(row: row, section: 0)).minY - table.bounds.height * 0.26
          guard target?.start == max(0, lyrics.line[row].start! - offset),
                table.lastIndex == row, table.lyricModels[row].isActiveLine,
                table.isFollowingPlayback, table.suppressAutoScrollUntil == nil,
                table.indexPathForSelectedRow == nil,
                abs(table.contentOffset.y - expectedOffset) < 0.5 else {
            throw NSError(domain: "LyricsSeekSmoke", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Selecting row \(row) with offset \(offset) highlighted \(String(describing: table.lastIndex))"])
          }
          tracking.reportsDeceleration = false
        }
      }
      NSLog("LyricsSeekSmoke: decelerating taps force the selected line into view; late drag callbacks preserve following; exact milliseconds, backward/rapid selection and signed offsets passed")
    }

    func verifyActualLyricsTouches(in popup: PopupPlayerVC) async throws {
      var complete = false
      var selection: LyricsLine?
      var selectedAt: CFTimeInterval?
      var selectedRate: Double = 0
      let originalSelection = onLyricSelected
      onLyricSelected = { line in
        selection = line
        selectedAt = CACurrentMediaTime()
        selectedRate = popup.player.isPlaying ? popup.player.playbackRate.asDouble : 0
        originalSelection?(line)
      }
      let finish = UIButton(type: .system)
      finish.setTitle("Finish lyrics test", for: .normal)
      finish.accessibilityIdentifier = "player.finishLyricsTouchTest"
      finish.accessibilityValue = popup.areLyricsControlsHidden ? "hidden" : "shown"
      finish.frame = CGRect(x: 12, y: popup.view.safeAreaInsets.top + 6, width: 180, height: 32)
      finish.addAction(UIAction { _ in complete = true }, for: .touchUpInside)
      popup.view.addSubview(finish)
      defer {
        finish.removeFromSuperview()
        onLyricSelected = originalSelection
      }
      let started = CACurrentMediaTime()
      while !complete && CACurrentMediaTime() - started < 90 {
        let value = popup.areLyricsControlsHidden ? "hidden" : "shown"
        if finish.accessibilityValue != value { finish.accessibilityValue = value }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard complete, let selection, let selectedAt, let start = selection.start, let lyrics,
            let selectedIndex = lyrics.line.lastIndex(where: {
              $0.value == selection.value && $0.start.map { max(0, $0 - lyrics.offset) } == start
            }) else {
        throw NSError(domain: "LyricsTouchSmoke", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Actual lyrics touch session did not finish with a selected line"])
      }
      for _ in 0..<4 {
        let actual = popup.player.elapsedTime
        // Audio keeps playing while XCTest checks accessibility and taps Finish.
        let expected = Double(start) / 1000 + (CACurrentMediaTime() - selectedAt) * selectedRate
        layoutIfNeeded()
        guard abs(actual - expected) < 1,
              lastIndex == selectedIndex,
              lyricModels[selectedIndex].isActiveLine,
              let cell = lyricModels[selectedIndex].cell,
              visibleCells.contains(where: { $0 === cell }),
              cell.isPlaybackEmphasisVisible,
              popup.areLyricsControlsHidden else {
          throw NSError(domain: "LyricsTouchSmoke", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Audio/visible lyric mismatch: target \(start) ms, expected \(expected), actual \(actual), row \(String(describing: lastIndex))"])
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      NSLog("LyricsTouchSmoke: actual bottom tap stayed immersive; down revealed, up hid; tapped lyric followed the audio clock and visible text emphasis without a test-driven refresh")
    }
  }

  private final class LyricsDecelerationSmokeView: LyricsView {
    var reportsDeceleration = false
    override var isDecelerating: Bool { reportsDeceleration || super.isDecelerating }
  }
#endif
