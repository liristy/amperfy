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
import CoreImage
import UIKit

fileprivate struct LyricCueAppearance: Equatable {
  let progress: CGFloat
  let lift: CGFloat
}

private actor LyricBlurRenderer {
  static let shared = LyricBlurRenderer()
  private let context = CIContext(options: [.cacheIntermediates: false])

  func render(_ image: CGImage, radius: CGFloat) -> CGImage? {
    guard !Task.isCancelled else { return nil }
    let source = CIImage(cgImage: image)
    let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    return context.createCGImage(blurred, from: source.extent)
  }
}

@MainActor
class LyricTableCellModel {
  private struct CueTiming {
    let cue: LyricCue
    let duration: Double
    let nextCueStart: Double?
  }

  struct TextLine {
    let value: String
    var start: Int? = nil
    var end: Int? = nil
    var cues: [LyricCue] = []
    var alignsRight = false
    var isTranslation = false

    var attributedText: NSAttributedString {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 5
      paragraph.lineBreakMode = .byWordWrapping
      paragraph.alignment = alignsRight ? .right : .natural
      let font = UIFontMetrics(forTextStyle: isTranslation ? .body : .title1).scaledFont(
        for: .systemFont(ofSize: isTranslation ? 17 : 32, weight: isTranslation ? .semibold : .bold),
        maximumPointSize: isTranslation ? 27 : 48
      )
      return NSAttributedString(string: value, attributes: [
        .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
      ])
    }
  }

  let lyric: LyricsLine
  let textLines: [TextLine]
  let interludeEnd: Int?
  let explicitEnd: Int?
  let nextLineStart: Int?
  weak var cell: LyricTableCell?
  fileprivate private(set) var cueAppearance: [[LyricCueAppearance]] = []
  fileprivate private(set) var vocalOpacity: [CGFloat] = []
  fileprivate private(set) var interludeProgress: CGFloat = 0
  fileprivate var blurredImage: (size: CGSize, scale: CGFloat, image: UIImage)?
  private let cueTimings: [[CueTiming]]
  let needsAnimation: Bool
  private var measuredLayout: (width: CGFloat, fontSize: CGFloat, frames: [CGRect])?
  var isActiveLine = false {
    didSet { if oldValue != isActiveLine { cell?.refreshEmphasis(animated: true) } }
  }

  init(lyric: LyricsLine, nextLineStart: Int?, rightAligned: Set<Int>,
       showsTranslation: Bool, interludeEnd: Int?) {
    self.lyric = lyric
    self.nextLineStart = nextLineStart
    self.interludeEnd = interludeEnd
    explicitEnd = lyric.vocals.compactMap(\.end).max() ?? lyric.cues.last?.end
    var lines = lyric.vocals.enumerated().map { index, vocal in
      TextLine(value: vocal.value, start: vocal.start, end: vocal.end, cues: vocal.cues,
               alignsRight: rightAligned.contains(index))
    }
    if lines.isEmpty, interludeEnd == nil {
      lines.append(TextLine(value: lyric.value, start: lyric.start, cues: lyric.cues,
                            alignsRight: rightAligned.contains(0)))
    }
    if showsTranslation, let translation = lyric.translation {
      lines.append(TextLine(value: translation.value, start: translation.start,
                            end: translation.end, cues: translation.cues,
                            alignsRight: rightAligned.contains(0), isTranslation: true))
    }
    textLines = lines
    needsAnimation = interludeEnd != nil || lines.contains {
      !$0.cues.isEmpty || (!$0.isTranslation && $0.start != lyric.start)
    }
    cueTimings = lines.map { line in
      line.cues.enumerated().map { index, cue in
        let nextCueStart = line.cues.dropFirst(index + 1).first?.start
        let followingStart = nextLineStart.flatMap { $0 > cue.start ? $0 : nil }
        let end = cue.end ?? nextCueStart ?? line.end ?? followingStart
        let duration = end.map { max(0, Double($0) - Double(cue.start)) } ?? 1_000
        return CueTiming(cue: cue, duration: duration, nextCueStart: nextCueStart.map(Double.init))
      }
    }
  }

  func updateCues(at time: Double) {
    if let start = lyric.start, let end = interludeEnd, end > start {
      let progress = CGFloat(min(1, max(0, (time - Double(start)) / Double(end - start))))
      guard progress != interludeProgress else { return }
      interludeProgress = progress
      cell?.refreshCueHighlight()
      return
    }
    guard needsAnimation else { return }
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    let fontSize = UIFontMetrics(forTextStyle: .title1).scaledValue(for: 32)
    let appearance = zip(textLines, cueTimings).map { line, timings in
      let maximumLift = min(48, fontSize) * (line.isTranslation ? 0.04 : 0.075)
      return timings.map { timing in
        let start = Double(timing.cue.start)
        let elapsed = time - start
        guard elapsed >= 0 else { return LyricCueAppearance(progress: 0, lift: 0) }
        let progress = timing.duration > 0 ? min(1, elapsed / timing.duration) : 1
        let wordEnd = start + timing.duration
        let settleStart = timing.nextCueStart ?? wordEnd
        let pickupDuration = max(1, min(680, min(wordEnd, settleStart) - start))
        let pickup = min(1, elapsed / pickupDuration)
        let settle = min(1, max(0, (time - settleStart) / 450))
        let lift = (pickup * pickup * (3 - 2 * pickup) + settle * settle * (3 - 2 * settle)) / 2
        return LyricCueAppearance(progress: CGFloat(progress), lift: reduceMotion ? 0 : maximumLift * CGFloat(lift))
      }
    }
    let opacity: [CGFloat] = textLines.map { line in
      guard !line.isTranslation, line.cues.isEmpty, let start = line.start, time < Double(start) else {
        return 1
      }
      return 0.48
    }
    guard appearance != cueAppearance || opacity != vocalOpacity else { return }
    cueAppearance = appearance
    vocalOpacity = opacity
    if isActiveLine { cell?.refreshCueHighlight() }
  }

  func textFrames(containerWidth: CGFloat) -> [CGRect] {
    let fontSize = UIFont.preferredFont(forTextStyle: .title1).pointSize
    if let measuredLayout, measuredLayout.width == containerWidth, measuredLayout.fontSize == fontSize {
      return measuredLayout.frames
    }
    var y: CGFloat = 12
    let width = max(1, containerWidth - 16)
    let frames = textLines.map { line in
      let inset = textLines.count(where: { !$0.isTranslation }) > 1 ? width * 0.16 : 0
      let lineWidth = width - inset
      let height = ceil(line.attributedText.boundingRect(
        with: CGSize(width: lineWidth, height: 10_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
      let frame = CGRect(x: 8 + (line.alignsRight ? inset : 0), y: y, width: lineWidth, height: height)
      y = frame.maxY + 6
      return frame
    }
    measuredLayout = (containerWidth, fontSize, frames)
    return frames
  }

  func calcHeight(containerWidth: CGFloat) -> CGFloat {
    (textFrames(containerWidth: containerWidth).last?.maxY ?? 42) + 16
  }
}

private final class LyricGlyphView: UIView {
  private struct Fragment {
    let glyphs: NSRange
    let bounds: CGRect
    let rightToLeft: Bool
  }

  private let textStorage = NSTextStorage()
  private let layoutManager = NSLayoutManager()
  private let textContainer = NSTextContainer(size: .zero)
  private let wipe = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.5).cgColor,
             UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
    locations: nil
  )
  private var cueRanges: [NSRange] = []
  private var cueFragments: [[Fragment]] = []
  private var untimedGlyphs: [NSRange] = []
  private var layoutWidth: CGFloat = -1
  private var hasCueLayout = false

  var appearance: [LyricCueAppearance] = [] {
    didSet { if oldValue != appearance { setNeedsDisplay() } }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = false
    textContainer.lineFragmentPadding = 0
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(textContainer)
  }

  required init?(coder: NSCoder) { return nil }

  func display(text: NSAttributedString, cues: [LyricCue]) {
    textStorage.setAttributedString(text)
    cueRanges = cues.map(\.range)
    layoutWidth = -1
    hasCueLayout = false
    appearance = []
    setNeedsDisplay()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    setNeedsDisplay()
  }

  private func prepareLayout() {
    guard layoutWidth != bounds.width else { return }
    layoutWidth = bounds.width
    textContainer.size = CGSize(width: max(1, bounds.width), height: 10_000)
    hasCueLayout = false
  }

  private func prepareCueLayout() {
    prepareLayout()
    guard !hasCueLayout else { return }
    hasCueLayout = true
    let glyphs = layoutManager.glyphRange(for: textContainer)
    var unassigned = IndexSet(integersIn: glyphs.location..<NSMaxRange(glyphs))
    cueFragments = cueRanges.map { range in
      guard NSMaxRange(range) <= textStorage.length else { return [] }
      let selected = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      guard selected.length > 0 else { return [] }
      let runs = Array(unassigned.rangeView(of: selected.location..<NSMaxRange(selected)))
      var fragments: [Fragment] = []
      for run in runs {
        let runRange = NSRange(location: run.lowerBound, length: run.count)
        layoutManager.enumerateLineFragments(forGlyphRange: runRange) { _, _, _, lineRange, _ in
          let glyphs = NSIntersectionRange(runRange, lineRange)
          guard glyphs.length > 0 else { return }
          let rect = self.layoutManager.boundingRect(forGlyphRange: glyphs, in: self.textContainer)
          var bidiLevel: UInt8 = 0
          self.layoutManager.getGlyphs(in: NSRange(location: glyphs.location, length: 1), glyphs: nil,
                                       properties: nil, characterIndexes: nil, bidiLevels: &bidiLevel)
          fragments.append(Fragment(glyphs: glyphs, bounds: rect, rightToLeft: bidiLevel % 2 == 1))
        }
        unassigned.remove(integersIn: run)
      }
      return fragments
    }
    untimedGlyphs = unassigned.rangeView.map { NSRange(location: $0.lowerBound, length: $0.count) }
  }

  private var textOrigin: CGPoint {
    let height = ceil(layoutManager.usedRect(for: textContainer).height)
    return CGPoint(x: 0, y: max(0, (bounds.height - height) / 2))
  }

  func drawPlain(at origin: CGPoint) {
    prepareLayout()
    let position = CGPoint(x: origin.x, y: origin.y + textOrigin.y)
    layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: textContainer), at: position)
  }

  override func draw(_ rect: CGRect) {
    guard !appearance.isEmpty, let context = UIGraphicsGetCurrentContext() else {
      drawPlain(at: .zero)
      return
    }
    prepareCueLayout()
    let origin = textOrigin
    let dimAlpha: CGFloat = 0.48
    context.saveGState()
    context.setAlpha(dimAlpha)
    for glyphs in untimedGlyphs {
      layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }
    context.restoreGState()
    for (fragments, cue) in zip(cueFragments, appearance) {
      let position = CGPoint(x: origin.x, y: origin.y - cue.lift)
      var remaining = fragments.reduce(CGFloat.zero) { $0 + $1.bounds.width } * cue.progress
      for fragment in fragments {
        let width = fragment.bounds.width
        let progress = width > 0 ? min(1, max(0, remaining / width)) : cue.progress
        draw(fragment: fragment, at: position, progress: progress, dimAlpha: dimAlpha, in: context)
        remaining -= width
      }
    }
  }

  private func draw(fragment: Fragment, at position: CGPoint, progress: CGFloat,
                    dimAlpha: CGFloat, in context: CGContext) {
    context.saveGState()
    context.setAlpha(progress >= 1 ? 1 : dimAlpha)
    layoutManager.drawGlyphs(forGlyphRange: fragment.glyphs, at: position)
    context.restoreGState()

    guard progress > 0, progress < 1, let wipe else { return }
    let bounds = fragment.bounds.offsetBy(dx: position.x, dy: position.y)
    let feather = min(12, max(5, bounds.width * 0.25))
    let direction: CGFloat = fragment.rightToLeft ? -1 : 1
    let edge = fragment.rightToLeft ? bounds.maxX : bounds.minX
    let front = edge + direction * ((bounds.width + 2 * feather) * progress - feather)
    context.saveGState()
    context.clip(to: bounds.insetBy(dx: -3, dy: -3))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    layoutManager.drawGlyphs(forGlyphRange: fragment.glyphs, at: position)
    context.setBlendMode(.destinationIn)
    context.drawLinearGradient(wipe, start: CGPoint(x: front - direction * feather, y: 0),
                               end: CGPoint(x: front + direction * feather, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.setBlendMode(.normal)
    context.endTransparencyLayer()
    context.restoreGState()
  }
}

class LyricTableCell: UITableViewCell {
  private weak var viewModel: LyricTableCellModel?
  private let motionContent = UIView()
  private let sharpLyrics = UIView()
  private let blurredLyrics = UIImageView()

  #if DEBUG && targetEnvironment(simulator)
    var hasVisibleBlurForSmokeTest: Bool { blurredLyrics.image != nil && blurredLyrics.alpha > 0 }
  #endif
  private var glyphViews = [LyricGlyphView]()
  private let dots = (0..<3).map { _ in UIView() }
  private static let dotSize: CGFloat = 14
  private var blurTask: Task<Void, Never>?
  private var requestedSize: CGSize = .zero
  private var requestedScale: CGFloat = 0
  var isBrowsing = false {
    didSet { if oldValue != isBrowsing { refreshEmphasis(animated: true) } }
  }

  var scrollLift: CGFloat {
    get { motionContent.transform.ty }
    set {
      guard abs(scrollLift - newValue) > 0.025 || (newValue == 0 && scrollLift != 0) else { return }
      motionContent.transform = CGAffineTransform(translationX: 0, y: newValue)
    }
  }

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
    blurredLyrics.isUserInteractionEnabled = false
    blurredLyrics.isAccessibilityElement = false
    motionContent.isUserInteractionEnabled = false
    contentView.addSubview(motionContent)
    motionContent.addSubview(blurredLyrics)
    motionContent.addSubview(sharpLyrics)
    for dot in dots {
      dot.backgroundColor = .white
      dot.layer.cornerRadius = Self.dotSize / 2
      sharpLyrics.addSubview(dot)
    }
    isAccessibilityElement = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    motionContent.bounds.size = contentView.bounds.size
    motionContent.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    sharpLyrics.frame = motionContent.bounds
    blurredLyrics.frame = sharpLyrics.frame.insetBy(dx: -8, dy: -8)
    let frames = viewModel?.textFrames(containerWidth: bounds.width) ?? []
    for (view, frame) in zip(glyphViews, frames) { view.frame = frame }
    for (index, dot) in dots.enumerated() {
      dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
      dot.center = CGPoint(x: 8 + Self.dotSize / 2 + CGFloat(index) * 23, y: bounds.midY)
    }
    if prepareBlurredLyricsIfNeeded() { updateAlpha(animated: false) }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = nil
    cancelBlur()
    scrollLift = 0
    sharpLyrics.layer.removeAllAnimations()
    blurredLyrics.layer.removeAllAnimations()
    blurredLyrics.image = nil
  }

  func display(model: LyricTableCellModel) {
    // reloadData can bind a replacement cell before UIKit recycles the old one.
    // Only detach the binding that this cell still owns.
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = model
    model.cell = self
    cancelBlur()
    scrollLift = 0
    sharpLyrics.layer.removeAllAnimations()
    blurredLyrics.layer.removeAllAnimations()
    blurredLyrics.image = nil
    if glyphViews.count > model.textLines.count {
      glyphViews.suffix(from: model.textLines.count).forEach { $0.removeFromSuperview() }
      glyphViews.removeLast(glyphViews.count - model.textLines.count)
    }
    while glyphViews.count < model.textLines.count {
      let view = LyricGlyphView(frame: .zero)
      sharpLyrics.addSubview(view)
      glyphViews.append(view)
    }
    for (view, line) in zip(glyphViews, model.textLines) {
      view.display(text: line.attributedText, cues: line.cues)
    }
    let isInterlude = model.interludeEnd != nil
    for dot in dots { dot.isHidden = !isInterlude }
    accessibilityLabel = isInterlude ? "Instrumental".localized :
      model.textLines.map(\.value).joined(separator: "\n")
    refreshEmphasis(animated: false)
    setNeedsLayout()
  }

  func refreshEmphasis(animated: Bool) {
    guard let model = viewModel else { return }
    refreshCueHighlight()
    accessibilityTraits = model.isActiveLine ? [.staticText, .selected] : .staticText
    isAccessibilityElement = model.interludeEnd == nil || model.isActiveLine
    if isBrowsing { cancelBlur() }
    _ = prepareBlurredLyricsIfNeeded()
    updateAlpha(animated: animated)
  }

  func refreshCueHighlight() {
    guard let model = viewModel else { return }
    for (index, view) in glyphViews.enumerated() {
      let hasAppearance = model.cueAppearance.indices.contains(index)
      view.appearance = model.isActiveLine && hasAppearance ? model.cueAppearance[index] : []
      let opacity = hasAppearance ? model.vocalOpacity[index] : 1
      view.alpha = model.textLines[index].isTranslation ? 0.66 : model.isActiveLine ? opacity : 1
    }
    guard model.interludeEnd != nil else { return }
    for (index, dot) in dots.enumerated() {
      let progress = min(1, max(0, model.interludeProgress * 3 - CGFloat(index)))
      let fillRate: CGFloat = index == 2 ? 1 : 1.65
      dot.alpha = 0.28 + 0.72 * min(1, fillRate * progress)
      let lift = UIAccessibility.isReduceMotionEnabled ? 0 : 1.76 * progress
      dot.transform = CGAffineTransform(translationX: 0, y: -lift)
    }
  }

  private func updateAlpha(animated: Bool) {
    guard let model = viewModel else { return }
    let changes = {
      let blurred = !model.isActiveLine && !self.isBrowsing && self.blurredLyrics.image != nil
      if model.interludeEnd != nil {
        self.sharpLyrics.alpha = model.isActiveLine ? 1 : 0
      } else {
        self.sharpLyrics.alpha = model.isActiveLine ? 1 : blurred ? 0 : self.isBrowsing ? 0.64 : 0.39
      }
      self.blurredLyrics.alpha = blurred ? 0.39 : 0
    }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: model.interludeEnd == nil ? 0.40 : 0.18, delay: 0,
                     options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
                     animations: changes)
    } else { changes() }
  }

  private func cancelBlur() {
    blurTask?.cancel()
    blurTask = nil
  }

  // Cache a small blurred copy on the lyric row. Only the text snapshot
  // touches UIKit; image filtering runs outside the playback animation.
  @discardableResult
  private func prepareBlurredLyricsIfNeeded() -> Bool {
    guard let model = viewModel, !model.isActiveLine, !isBrowsing, !glyphViews.isEmpty,
          UIApplication.shared.applicationState == .active
    else { return false }
    let size = sharpLyrics.bounds.size
    guard size.width > 0, size.height > 0, glyphViews.allSatisfy({ $0.bounds.width > 0 }) else {
      return false
    }
    let scale = min(1.5, max(1, traitCollection.displayScale))
    if let cached = model.blurredImage, cached.size == size, cached.scale == scale {
      guard blurredLyrics.image !== cached.image else { return false }
      blurredLyrics.image = cached.image
      return true
    }
    guard blurTask == nil || requestedSize != size || requestedScale != scale else { return false }
    cancelBlur()
    blurredLyrics.image = nil
    requestedSize = size
    requestedScale = scale
    let padding: CGFloat = 8
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let image = UIGraphicsImageRenderer(size: CGSize(width: size.width + padding * 2,
      height: size.height + padding * 2), format: format).image { _ in
      for view in glyphViews {
        view.drawPlain(at: CGPoint(x: view.frame.minX + padding, y: view.frame.minY + padding))
      }
    }
    guard let source = image.cgImage else { return false }
    blurTask = Task { [weak self, weak model] in
      let rendered = await LyricBlurRenderer.shared.render(source, radius: 1.5 * scale)
      guard !Task.isCancelled, let self, let model, viewModel === model else { return }
      blurTask = nil
      guard let rendered else { return }
      let image = UIImage(cgImage: rendered, scale: scale, orientation: .up)
      model.blurredImage = (size, scale, image)
      blurredLyrics.image = image
      if !model.isActiveLine, !isBrowsing { updateAlpha(animated: true) }
    }
    return false
  }
}
