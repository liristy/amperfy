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

final class LyricsTranslationButton: UIButton {
  weak var lyricsView: LyricsView?

  override init(frame: CGRect) {
    super.init(frame: frame)
    accessibilityLabel = "Lyrics Translation".localized
    isHidden = true
    addAction(UIAction { [weak self] _ in
      self?.lyricsView?.toggleTranslation()
      self?.refresh()
    }, for: .touchUpInside)
  }

  required init?(coder: NSCoder) { nil }

  func refresh() {
    isHidden = lyricsView?.hasTranslation != true || lyricsView?.isHidden != false
    isSelected = lyricsView?.showsTranslation == true
    var style = UIButton.Configuration.filled()
    style.cornerStyle = .capsule
    style.image = UIImage(systemName: "translate") ?? UIImage(systemName: "character.bubble")
    style.preferredSymbolConfigurationForImage = .init(pointSize: 18, weight: .semibold)
    style.baseForegroundColor = isSelected ? .black : .white
    style.baseBackgroundColor = .white.withAlphaComponent(isSelected ? 0.92 : 0.22)
    configuration = style
  }
}

class LyricsView: UITableView, UITableViewDataSource, UITableViewDelegate {
  private struct ScrollTransition {
    struct Sample {
      let position: CGFloat
      let velocity: CGFloat
      var acceleration: CGFloat = 0
    }

    static let maximumDuration: CFTimeInterval = 1.2

    let start: Sample
    let target: CGFloat
    let focusedRow: Int
    let rowStarts: [Int: Sample]
    let startTime = CACurrentMediaTime()

    func sample(after elapsed: CFTimeInterval, forRow row: Int? = nil) -> Sample {
      let distance = CGFloat(row.map { max(0, $0 - focusedRow) } ?? 0)
      let previous = row.flatMap { rowStarts[$0] }
      let initial = previous ?? start
      let isMoving = abs(initial.velocity) > 0.1 || abs(initial.acceleration) > 0.5
      let delay = isMoving ? 0 : min(8, distance) * 0.05
      let time = max(0, CGFloat(elapsed) - delay)
      if time >= 0.8 { return Sample(position: target, velocity: 0) }
      let damping: CGFloat = 19.2
      let displacement = initial.position - target
      let linear = initial.velocity + damping * displacement
      let quadratic = (initial.acceleration + 2 * damping * initial.velocity +
        damping * damping * displacement) / 2
      let position = displacement + linear * time + quadratic * time * time
      let velocity = linear + 2 * quadratic * time
      let decay = exp(-damping * time)
      return Sample(position: target + position * decay,
                    velocity: (velocity - damping * position) * decay,
                    acceleration: (2 * quadratic - 2 * damping * velocity +
                      damping * damping * position) * decay)
    }

    func hasSettled(after elapsed: CFTimeInterval) -> Bool {
      if elapsed >= Self.maximumDuration { return true }
      let tail = sample(after: elapsed, forRow: focusedRow + 12)
      return abs(target - tail.position) < 0.18 && abs(tail.velocity) < 1.6
    }
  }

  private var lyrics: StructuredLyrics?
  private var displayLyrics: StructuredLyrics?
  private var lyricModels: [LyricTableCellModel] = []
  private var overlappingRows = [Int]()
  private var activeRows = Set<Int>()
  private var lastScrolledIndex: Int?
  private var lastPlaybackTime: CMTime?
  private var scrollTransition: ScrollTransition?
  private var renderedScrollElapsed: CFTimeInterval = 0
  private var displayLink: CADisplayLink?
  private var scrollAnimation = true
  private var isBrowsing = false
  private var browsingTimeout: Task<Void, Never>?
  private let edgeMask = CAGradientLayer()
  private var previousSize: CGSize = .zero
  var playbackPosition: (() -> TimeInterval?)?
  var hasTranslation: Bool { lyrics?.line.contains { $0.translation != nil } ?? false }
  private(set) var showsTranslation = UserDefaults.standard.bool(forKey: "showsLyricsTranslation")
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
    estimatedRowHeight = 0
    backgroundColor = .clear
    showsVerticalScrollIndicator = false
    contentInsetAdjustmentBehavior = .never
    dataSource = self
    delegate = self
    panGestureRecognizer.addTarget(self, action: #selector(didPanLyrics(_:)))
    edgeMask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor,
                       UIColor.white.cgColor, UIColor.clear.cgColor]
    edgeMask.locations = [0, 0.08, 0.90, 1]
    layer.mask = edgeMask
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      finishBrowsing()
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
    if lastScrolledIndex == nil, !isBrowsing, activeRows.isEmpty {
      setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
    }
  }

  private func updateContentInset() {
    // Cap the reading inset on tall layouts so it stays put as controls move.
    let top = min(bounds.height * 0.382, min(520, bounds.width) * 0.26)
    contentInset = UIEdgeInsets(top: top, left: 0,
                               bottom: max(0, bounds.height * 0.91 - top), right: 0)
  }

  public func display(lyrics: StructuredLyrics, scrollAnimation: Bool) {
    self.scrollAnimation = scrollAnimation
    let translationPreference = UserDefaults.standard.bool(forKey: "showsLyricsTranslation")
    // Playback notifications can repeat for the same song. Keep the reading position.
    if let current = self.lyrics, current.synced == lyrics.synced,
       current.offset == lyrics.offset, current.line == lyrics.line {
      if showsTranslation != translationPreference { setTranslationVisible(translationPreference) }
      return
    }
    showsTranslation = translationPreference
    stopScrollTransition()
    stopDisplayLink()
    finishBrowsing()
    self.lyrics = lyrics
    rebuildRows()
    updateContentInset()
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    reloadData()
    setContentOffset(CGPoint(x: 0, y: -contentInset.top), animated: false)
  }

  func toggleTranslation() {
    guard hasTranslation else { return }
    let visible = !showsTranslation
    UserDefaults.standard.set(visible, forKey: "showsLyricsTranslation")
    setTranslationVisible(visible)
  }

  private func setTranslationVisible(_ visible: Bool) {
    showsTranslation = visible
    if scrollTransition != nil { lastScrolledIndex = nil }
    stopScrollTransition()
    let offset = contentOffset.y
    let anchor = indexPathForRow(at: CGPoint(x: bounds.midX, y: offset + contentInset.top))
    let previousY = anchor.map { rectForRow(at: $0).minY } ?? 0
    rebuildRows()
    reloadData()
    layoutIfNeeded()
    if let anchor {
      let target = offset + rectForRow(at: anchor).minY - previousY
      setContentOffset(CGPoint(x: 0, y: max(-contentInset.top, target)), animated: false)
    }
    if let lastPlaybackTime { scroll(toTime: lastPlaybackTime) }
  }

  private func rebuildRows() {
    guard var lyrics else { return }
    var interludes = [Int: Int]()
    if lyrics.synced {
      var lines = [LyricsLine]()
      var previousEnd = 0
      var blankStart: Int?
      for line in lyrics.line {
        guard let start = line.start else {
          lines.append(line)
          continue
        }
        if line.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, line.vocals.isEmpty {
          blankStart = blankStart ?? start
          continue
        }
        let gapStart = max(previousEnd, blankStart ?? previousEnd)
        if start > gapStart, lines.isEmpty || blankStart != nil || start - gapStart >= 3_000 {
          var gap = LyricsLine()
          gap.start = gapStart
          interludes[lines.count] = start
          lines.append(gap)
        }
        let end = (line.vocals.compactMap(\.end) + line.cues.compactMap(\.end)).max() ??
          (start + 5_000)
        previousEnd = max(previousEnd, end)
        blankStart = nil
        lines.append(line)
      }
      lyrics.line = lines
    }
    displayLyrics = lyrics
    let nextStarts = lyrics.line.indices.map { row in
      lyrics.line.dropFirst(row + 1).lazy.compactMap(\.start).first { $0 > (lyrics.line[row].start ?? -1) }
    }
    let rightAligned = vocalSides(in: lyrics.line, nextStarts: nextStarts)
    lyricModels = lyrics.line.enumerated().map { index, line in
      let model = LyricTableCellModel(lyric: line, nextLineStart: nextStarts[index],
        rightAligned: rightAligned[index] ?? [], showsTranslation: showsTranslation,
        interludeEnd: interludes[index])
      model.isActiveLine = !lyrics.synced
      return model
    }
    overlappingRows = lyricModels.indices.dropLast().filter { row in
      guard let end = lyricModels[row].explicitEnd ?? lyricModels[row].nextLineStart,
            let nextStart = lyricModels[row + 1].lyric.start else { return false }
      return end > nextStart
    }
    activeRows.removeAll()
  }

  private func vocalSides(in lines: [LyricsLine], nextStarts: [Int?]) -> [Int: Set<Int>] {
    struct Voice {
      let row: Int
      let index: Int
      let value: String
      let start: Int
      let end: Int
      let agentID: String?
    }
    var voices = [Voice]()
    for (row, line) in lines.enumerated() {
      guard let start = line.start else { continue }
      if line.vocals.isEmpty {
        guard !line.value.isEmpty else { continue }
        voices.append(Voice(row: row, index: 0, value: line.value, start: start,
          end: line.cues.compactMap(\.end).max() ?? nextStarts[row] ?? Int.max, agentID: nil))
      } else {
        for (index, vocal) in line.vocals.enumerated() {
          voices.append(Voice(row: row, index: index, value: vocal.value, start: vocal.start ?? start,
            end: vocal.end ?? nextStarts[row] ?? Int.max, agentID: vocal.agentID))
        }
      }
    }
    var active = [Int]()
    var sides = [Int: Bool]()
    var agentSides = [String: Bool]()
    var rightAligned = [Int: Set<Int>]()
    for (index, voice) in voices.enumerated().sorted(by: { $0.element.start < $1.element.start }) {
      active.removeAll { voices[$0].end <= voice.start }
      guard voice.end > voice.start else { continue }
      for previousIndex in active {
        let previous = voices[previousIndex]
        guard previous.value != voice.value,
              voice.agentID == nil || previous.agentID != voice.agentID else { continue }
        let previousSide = sides[previousIndex] ?? previous.agentID.flatMap { agentSides[$0] } ?? false
        let side = sides[index] ?? voice.agentID.flatMap { agentSides[$0] } ?? !previousSide
        sides[previousIndex] = previousSide
        sides[index] = side
        if let agent = previous.agentID { agentSides[agent] = previousSide }
        if let agent = voice.agentID { agentSides[agent] = side }
      }
      active.append(index)
    }
    for (index, voice) in voices.enumerated() {
      if sides[index] ?? voice.agentID.flatMap({ agentSides[$0] }) ?? false {
        rightAligned[voice.row, default: []].insert(voice.index)
      }
    }
    return rightAligned
  }

  public func highlightAllLyrics() { lyricModels.forEach { $0.isActiveLine = true } }

  #if DEBUG && targetEnvironment(simulator)
    func indexPathForLyric(startingAt milliseconds: Int) -> IndexPath? {
      lyricModels.firstIndex { $0.lyric.start == milliseconds && $0.interludeEnd == nil }
        .map { IndexPath(row: $0, section: 0) }
    }
  #endif

  public func clear() {
    stopScrollTransition()
    stopDisplayLink()
    finishBrowsing()
    lyrics = nil
    displayLyrics = nil
    lyricModels.removeAll()
    overlappingRows.removeAll()
    activeRows.removeAll()
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    reloadData()
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    lyricModels.count
  }

  public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    lyricModels[indexPath.row].calcHeight(containerWidth: bounds.width)
  }

  public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = dequeueReusableCell(withIdentifier: LyricTableCell.typeName, for: indexPath) as! LyricTableCell
    cell.display(model: lyricModels[indexPath.row])
    cell.isBrowsing = isBrowsing
    return cell
  }

  public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                        forRowAt indexPath: IndexPath) {
    if let cell = cell as? LyricTableCell {
      cell.isBrowsing = isBrowsing
      applyScrollLift(to: cell, row: indexPath.row)
    }
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
    finishBrowsing()
    lastScrolledIndex = nil
    lastPlaybackTime = nil
    onLyricSelected?(lyric)
    scroll(toTime: lyric.startTime)
  }

  public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    stopScrollTransition()
    lastScrolledIndex = nil
    browsingTimeout?.cancel()
    setBrowsing(true)
  }

  func handleDrag(translation: CGPoint, velocity: CGPoint) {
    guard abs(translation.y) >= 56, abs(translation.y) > abs(translation.x) * 1.3,
          abs(velocity.y) >= 500, abs(velocity.y) > abs(velocity.x) * 1.3 else { return }
    if translation.y < 0, velocity.y < 0 { onUpwardDrag?() }
    else if translation.y > 0, velocity.y > 0 { onDownwardDrag?() }
  }

  @objc private func didPanLyrics(_ pan: UIPanGestureRecognizer) {
    guard pan.state == .ended, let window else { return }
    handleDrag(translation: pan.translation(in: window), velocity: pan.velocity(in: window))
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { scheduleBrowsingEnd() }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    scheduleBrowsingEnd()
  }

  private func scheduleBrowsingEnd() {
    browsingTimeout?.cancel()
    browsingTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let self else { return }
      finishBrowsing()
      if let lastPlaybackTime { scroll(toTime: lastPlaybackTime) }
    }
  }

  private func finishBrowsing() {
    browsingTimeout?.cancel()
    browsingTimeout = nil
    setBrowsing(false)
  }

  private func setBrowsing(_ value: Bool) {
    isBrowsing = value
    for case let cell as LyricTableCell in visibleCells { cell.isBrowsing = value }
  }

  func scroll(toTime time: CMTime) {
    guard let lyrics = displayLyrics, lyrics.synced, !lyricModels.isEmpty else { return }
    let timeStep = lastPlaybackTime.map { CMTimeSubtract(time, $0).seconds } ?? 0
    lastPlaybackTime = time
    let index = lyrics.activeLineIndex(at: time)
    let milliseconds = lyrics.adjustedTime(for: time).seconds * 1_000
    var singing = Set<Int>()
    if let index {
      singing.insert(index)
      for row in overlappingRows where row < index {
        let model = lyricModels[row]
        guard let start = model.lyric.start, let end = model.explicitEnd ?? model.nextLineStart,
              milliseconds >= Double(start), milliseconds < Double(end) else { continue }
        singing.insert(row)
      }
    }
    for row in activeRows.subtracting(singing) { lyricModels[row].isActiveLine = false }
    for row in singing {
      lyricModels[row].updateCues(at: milliseconds)
      lyricModels[row].isActiveLine = true
    }
    activeRows = singing
    if singing.contains(where: { lyricModels[$0].needsAnimation }), playbackPosition?() != nil {
      startDisplayLink()
    }
    let focus = singing.min()
    let row = singing.count > 1 ? focus : readingRow(active: focus, in: lyrics, at: time, timeStep: timeStep)
    guard let row, row != lastScrolledIndex, !isDragging, !isDecelerating, !isBrowsing else { return }
    layoutIfNeeded()
    let rect = rectForRow(at: IndexPath(row: row, section: 0))
    let target = max(-contentInset.top, rect.minY - contentInset.top)
    let animated = scrollAnimation && !UIAccessibility.isReduceMotionEnabled && lastScrolledIndex != nil
    let nextLine = lastScrolledIndex.map { row == $0 + 1 } ?? false
    if animated, nextLine, timeStep >= 0, timeStep <= 0.50, target > contentOffset.y, window != nil {
      startScrollTransition(to: target, focusedRow: row)
    } else {
      stopScrollTransition()
      setContentOffset(CGPoint(x: 0, y: target), animated: animated)
    }
    lastScrolledIndex = row
  }

  private func readingRow(active: Int?, in lyrics: StructuredLyrics, at time: CMTime,
                          timeStep: TimeInterval) -> Int? {
    guard let active, scrollAnimation, !UIAccessibility.isReduceMotionEnabled,
          lastScrolledIndex != nil, lyrics.line.indices.contains(active + 1),
          let nextStart = lyrics.line[active + 1].start else { return active }
    if overlappingRows.contains(active) { return active }
    let remaining = Double(nextStart) / 1_000 - lyrics.adjustedTime(for: time).seconds
    guard remaining > 0, remaining <= 0.48 else { return active }
    // The row can start to glide before the beat. Highlighting still uses the actual playback time.
    if lastScrolledIndex == active + 1 && timeStep >= 0 && timeStep <= 0.50 { return active + 1 }
    guard timeStep > 0, timeStep <= 0.50, playbackPosition?() != nil else { return active }
    return active + 1
  }

  private func startScrollTransition(to target: CGFloat, focusedRow: Int) {
    var rowStarts = [Int: ScrollTransition.Sample]()
    let previous = scrollTransition
    if let previous {
      for cell in visibleCells {
        if let cell = cell as? LyricTableCell, let index = indexPath(for: cell) {
          let sample = previous.sample(after: renderedScrollElapsed, forRow: index.row)
          rowStarts[index.row] = .init(position: contentOffset.y - cell.scrollLift,
                                       velocity: sample.velocity, acceleration: sample.acceleration)
        }
      }
    }
    let sample = previous?.sample(after: renderedScrollElapsed)
    let start = ScrollTransition.Sample(position: contentOffset.y, velocity: sample?.velocity ?? 0,
                                        acceleration: sample?.acceleration ?? 0)
    scrollTransition = ScrollTransition(start: start, target: target, focusedRow: focusedRow,
                                        rowStarts: rowStarts)
    renderedScrollElapsed = 0
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
    let animatesLyrics = activeRows.contains { lyricModels[$0].needsAnimation }
    let position = animatesLyrics ? playbackPosition?() : nil
    let seconds = position.flatMap { $0.isFinite ? $0 : nil }
    if let seconds {
      scroll(toTime: CMTime(seconds: seconds, preferredTimescale: 10_000))
    }
    if let transition = scrollTransition {
      renderedScrollElapsed = max(0, link.targetTimestamp - transition.startTime)
      if transition.hasSettled(after: renderedScrollElapsed) || UIAccessibility.isReduceMotionEnabled {
        setContentOffset(CGPoint(x: 0, y: transition.target), animated: false)
        stopScrollTransition()
      } else {
        let offset = transition.sample(after: renderedScrollElapsed).position
        if abs(contentOffset.y - offset) > 0.05 {
          setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        }
        for cell in visibleCells {
          guard let cell = cell as? LyricTableCell, let index = indexPath(for: cell) else { continue }
          applyScrollLift(to: cell, row: index.row)
        }
      }
    }
    if scrollTransition == nil, seconds == nil { stopDisplayLink() }
  }

  private func applyScrollLift(to cell: LyricTableCell, row: Int) {
    guard let transition = scrollTransition else {
      cell.scrollLift = 0
      return
    }
    let position = transition.sample(after: renderedScrollElapsed, forRow: row).position
    cell.scrollLift = contentOffset.y - position
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
