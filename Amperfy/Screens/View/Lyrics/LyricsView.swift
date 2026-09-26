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

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    edgeMask.frame = bounds
    CATransaction.commit()
    guard bounds.size != previousSize else { return }
    previousSize = bounds.size
    contentInset = UIEdgeInsets(top: bounds.height * 0.26, left: 0,
                               bottom: bounds.height * 0.65, right: 0)
    // Recalculate wrapping after rotation without fighting normal scrolling.
    reloadData()
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
    suppressAutoScrollUntil = nil
    lastScrolledIndex = nil
    onLyricSelected?(lyric)
    scroll(toTime: lyric.startTime)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    lastScrolledIndex = nil
    suppressAutoScrollUntil = Date().addingTimeInterval(5)
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
