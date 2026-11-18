//
//  LyricTableCell.swift
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
import CoreData
import CoreImage
import UIKit

@MainActor
class LyricTableCellModel {
  private struct CueAppearance: Equatable {
    var brightness = 0
    var lift = 0
  }

  let lyric: LyricsLine
  weak var cell: LyricTableCell?
  private var cueAppearance: [CueAppearance] = []
  private var cueTime: Int64?
  var isActiveLine = false {
    didSet { if oldValue != isActiveLine { cell?.refresh(animated: true) } }
  }

  var displayString: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 5
    paragraph.lineBreakMode = .byWordWrapping
    let font = UIFontMetrics(forTextStyle: .title1).scaledFont(
      for: .systemFont(ofSize: 32, weight: .bold), maximumPointSize: 48)
    if !lyric.cues.isEmpty {
      // Reserve room for the lifted glyphs without moving the other baselines.
      paragraph.minimumLineHeight = ceil(font.lineHeight) + 2
      paragraph.maximumLineHeight = paragraph.minimumLineHeight
    }
    return NSAttributedString(string: lyric.value.isEmpty ? "•••" : lyric.value, attributes: [
      .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
    ])
  }

  init(lyric: LyricsLine) { self.lyric = lyric }

  func updateCues(at time: Int64) {
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let appearance = lyric.cues.enumerated().map { index, cue in
      guard time >= Int64(cue.start) else { return CueAppearance() }
      let elapsed = Double(time) - Double(cue.start)
      let nextStart = lyric.cues.dropFirst(index + 1).first?.start
      let end = cue.end ?? nextStart
      let duration = end.map { min(240, Double($0) - Double(cue.start)) } ?? 240
      let brightness = duration > 0 ? min(1, elapsed / duration) : 1
      let lift = reduceMotion ? 0 : 1 - pow(1 - min(1, elapsed / 360), 2)
      return CueAppearance(brightness: Int((brightness * 16).rounded()),
                           lift: Int((lift * 16).rounded()))
    }
    let wasAdvancing = cueTime.map { time > $0 && Double(time) - Double($0) <= 160 } ?? false
    cueTime = time
    guard appearance != cueAppearance else { return }
    cueAppearance = appearance
    if isActiveLine { cell?.refreshCueHighlight(animated: wasAdvancing) }
  }

  func highlightedString(from baseText: NSAttributedString) -> NSAttributedString {
    guard isActiveLine, !cueAppearance.isEmpty else { return baseText }
    let text = NSMutableAttributedString(attributedString: baseText)
    let dimAlpha: CGFloat = 0.58
    text.addAttribute(.foregroundColor, value: UIColor.white.withAlphaComponent(dimAlpha),
                      range: NSRange(location: 0, length: text.length))
    for (cue, appearance) in zip(lyric.cues, cueAppearance) where
      (appearance.brightness > 0 || appearance.lift > 0) && NSMaxRange(cue.range) <= text.length {
      let alpha = dimAlpha + (1 - dimAlpha) * CGFloat(appearance.brightness) / 16
      text.addAttributes([
        .foregroundColor: UIColor.white.withAlphaComponent(alpha),
        .baselineOffset: 2 * CGFloat(appearance.lift) / 16,
      ], range: cue.range)
    }
    return text
  }

  func calcHeight(containerWidth: CGFloat) -> CGFloat {
    ceil(displayString.boundingRect(
      with: CGSize(width: max(1, containerWidth - 16), height: 10_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
  }
}

class LyricTableCell: UITableViewCell {
  private weak var viewModel: LyricTableCellModel?
  private let lyricLabel = UILabel()
  private let blurredLyrics = UIImageView()
  private static let blurContext = CIContext(options: [.cacheIntermediates: false])
  private var baseText: NSAttributedString?
  private var renderedText: NSAttributedString?
  private var renderedSize: CGSize = .zero
  private var renderedScale: CGFloat = 0

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    backgroundColor = .clear
    selectionStyle = .none
    lyricLabel.numberOfLines = 0
    lyricLabel.textAlignment = .natural
    blurredLyrics.isUserInteractionEnabled = false
    blurredLyrics.isAccessibilityElement = false
    contentView.addSubview(blurredLyrics)
    contentView.addSubview(lyricLabel)
    isAccessibilityElement = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    lyricLabel.frame = CGRect(x: 8, y: 15, width: max(0, bounds.width - 16), height: max(0, bounds.height - 30))
    blurredLyrics.frame = lyricLabel.frame.insetBy(dx: -8, dy: -8)
    if renderBlurredLyricsIfNeeded() { updateEmphasis(animated: false) }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = nil
    contentView.transform = .identity
    lyricLabel.layer.removeAllAnimations()
    blurredLyrics.layer.removeAllAnimations()
    blurredLyrics.image = nil
    baseText = nil
    renderedText = nil
  }

  func display(model: LyricTableCellModel) {
    // reloadData can bind a replacement cell before UIKit recycles the old one.
    // Only detach the binding that this cell still owns.
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = model
    model.cell = self
    lyricLabel.layer.removeAllAnimations()
    blurredLyrics.layer.removeAllAnimations()
    refresh()
  }

  func refresh(animated: Bool = false) {
    guard let model = viewModel else { return }
    baseText = model.displayString
    refreshCueHighlight()
    accessibilityLabel = model.lyric.value
    accessibilityTraits = model.isActiveLine ? [.staticText, .selected] : .staticText
    _ = renderBlurredLyricsIfNeeded()
    updateEmphasis(animated: animated)
    setNeedsLayout()
  }

  func refreshCueHighlight(animated: Bool = false) {
    guard let model = viewModel, let baseText else { return }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      let transition = CATransition()
      transition.type = .fade
      transition.duration = 0.09
      lyricLabel.layer.add(transition, forKey: "lyricCueHighlight")
    } else {
      lyricLabel.layer.removeAnimation(forKey: "lyricCueHighlight")
    }
    lyricLabel.attributedText = model.highlightedString(from: baseText)
  }

  private func updateEmphasis(animated: Bool) {
    guard let model = viewModel else { return }
    let changes = {
      self.lyricLabel.alpha = model.isActiveLine ? 1 : (self.blurredLyrics.image == nil ? 0.32 : 0)
      self.blurredLyrics.alpha = model.isActiveLine ? 0 : 0.5
    }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
    } else { changes() }
  }

  // Rasterize only when the text, wrapping width or display scale changes.
  // Playback emphasis crossfades these two layers without rerunning the filter.
  @discardableResult
  private func renderBlurredLyricsIfNeeded() -> Bool {
    guard viewModel?.isActiveLine == false, UIApplication.shared.applicationState == .active
    else { return false }
    guard let text = lyricLabel.attributedText,
          lyricLabel.bounds.width > 0, lyricLabel.bounds.height > 0 else { return false }
    let size = lyricLabel.bounds.size
    let scale = max(1, traitCollection.displayScale)
    guard renderedSize != size || renderedScale != scale || renderedText?.isEqual(to: text) != true else { return false }
    let padding: CGFloat = 8
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let image = UIGraphicsImageRenderer(size: CGSize(width: size.width + padding * 2,
      height: size.height + padding * 2), format: format).image { _ in
      lyricLabel.drawText(in: CGRect(origin: CGPoint(x: padding, y: padding), size: size))
    }
    guard let source = CIImage(image: image) else { return false }
    let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.8 * scale])
      .cropped(to: source.extent)
    guard let result = Self.blurContext.createCGImage(blurred, from: source.extent) else { return false }
    blurredLyrics.image = UIImage(cgImage: result, scale: scale, orientation: .up)
    renderedText = text
    renderedSize = size
    renderedScale = scale
    return true
  }
}
