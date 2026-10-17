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
    reloadData()
    setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
  }

  public func highlightAllLyrics() { lyricModels.forEach { $0.isActiveLine = true } }

  public func clear() {
    lyrics = nil
    lyricModels.removeAll()
    lastIndex = nil
    lastScrolledIndex = nil
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
    // OpenSubsonic's positive offset means the line appears earlier.
    lyric.start = max(0, start - lyrics.offset)
    // Stop an older automatic scroll at its rendered position before centering
    // the selected line, rather than letting its animation pull the list back.
    let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
    setContentOffset(visibleOffset, animated: false)
    suppressAutoScrollUntil = nil
    lastScrolledIndex = nil
    onLyricSelected?(lyric)
    scroll(toTime: lyric.startTime)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
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
    let index = lyrics.activeLineIndex(at: time)
    if index != lastIndex {
      if let lastIndex { lyricModels[lastIndex].isActiveLine = false }
      if let index { lyricModels[index].isActiveLine = true }
      lastIndex = index
    }
    guard let index, index != lastScrolledIndex, !isDragging, !isDecelerating,
          suppressAutoScrollUntil.map({ Date() >= $0 }) ?? true else { return }
    layoutIfNeeded()
    let row = rectForRow(at: IndexPath(row: index, section: 0))
    let target = max(-contentInset.top, row.minY - bounds.height * 0.26)
    let animated = scrollAnimation && !UIAccessibility.isReduceMotionEnabled && lastScrolledIndex != nil
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
        lyrics.line = [0, 1001, 2002].map { start in
          var line = LyricsLine()
          line.start = start
          line.value = "Millisecond line \(start)"
          return line
        }
        let table = LyricsView(frame: CGRect(x: 0, y: 0, width: 360, height: 480), style: .plain)
        table.display(lyrics: lyrics, scrollAnimation: true)
        var target: LyricsLine?
        table.onLyricSelected = { target = $0 }
        for row in [2, 1, 2, 0] {
          table.tableView(table, didSelectRowAt: IndexPath(row: row, section: 0))
          guard target?.start == max(0, lyrics.line[row].start! - offset),
                table.lastIndex == row else {
            throw NSError(domain: "LyricsSeekSmoke", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Selecting row \(row) with offset \(offset) highlighted \(String(describing: table.lastIndex))"])
          }
        }
      }
      NSLog("LyricsSeekSmoke: exact millisecond taps, backward/rapid selection and signed offsets passed")
    }

    func verifyActualLyricsTouches(in popup: PopupPlayerVC) async throws {
      var complete = false
      var selection: LyricsLine?
      let originalSelection = onLyricSelected
      onLyricSelected = { line in
        selection = line
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
      guard complete, let selection, let start = selection.start, let lyrics,
            let selectedIndex = lyrics.line.lastIndex(where: {
              $0.value == selection.value && $0.start.map { max(0, $0 - lyrics.offset) } == start
            }) else {
        throw NSError(domain: "LyricsTouchSmoke", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Actual lyrics touch session did not finish with a selected line"])
      }
      for _ in 0..<4 {
        let actual = popup.player.elapsedTime
        scroll(toTime: StructuredLyrics.playbackTime(seconds: actual))
        layoutIfNeeded()
        guard abs(actual - Double(start) / 1000) < 2,
              lastIndex == selectedIndex,
              lyricModels[selectedIndex].cell?.accessibilityTraits.contains(.selected) == true,
              popup.areLyricsControlsHidden else {
          throw NSError(domain: "LyricsTouchSmoke", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Audio/visible lyric mismatch: target \(start) ms, actual \(actual), row \(String(describing: lastIndex))"])
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      NSLog("LyricsTouchSmoke: actual bottom tap stayed immersive; up revealed, down hid; tapped lyric matched audio and visible highlight")
    }
  }
#endif
