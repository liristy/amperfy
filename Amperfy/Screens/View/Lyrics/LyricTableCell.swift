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
import UIKit

@MainActor
class LyricTableCellModel {
  let lyric: LyricsLine?
  weak var cell: LyricTableCell?
  var isActiveLine = false {
    didSet { if oldValue != isActiveLine { cell?.refresh(animated: true) } }
  }

  var displayString: NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 5
    paragraph.lineBreakMode = .byWordWrapping
    let font = UIFontMetrics(forTextStyle: .title1).scaledFont(
      for: .systemFont(ofSize: 32, weight: .bold), maximumPointSize: 48)
    return NSAttributedString(string: lyric?.value.isEmpty == false ? lyric!.value : "•••", attributes: [
      .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
    ])
  }

  init(lyric: LyricsLine) { self.lyric = lyric }

  func calcHeight(containerWidth: CGFloat) -> CGFloat {
    ceil(displayString.boundingRect(
      with: CGSize(width: max(1, containerWidth - 16), height: 10_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
  }
}

class LyricTableCell: UITableViewCell {
  private weak var viewModel: LyricTableCellModel?
  private let lyricLabel = UILabel()

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
    contentView.addSubview(lyricLabel)
    isAccessibilityElement = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    lyricLabel.frame = CGRect(x: 8, y: 15, width: max(0, bounds.width - 16), height: max(0, bounds.height - 30))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = nil
    lyricLabel.layer.removeAllAnimations()
  }

  func display(model: LyricTableCellModel) {
    // reloadData can bind a replacement cell before UIKit recycles the old one.
    // Only detach the binding that this cell still owns.
    if viewModel?.cell === self { viewModel?.cell = nil }
    viewModel = model
    model.cell = self
    lyricLabel.layer.removeAllAnimations()
    refresh()
  }

  func refresh(animated: Bool = false) {
    guard let model = viewModel else { return }
    lyricLabel.attributedText = model.displayString
    accessibilityLabel = model.lyric?.value
    accessibilityTraits = model.isActiveLine ? [.staticText, .selected] : .staticText
    let changes = { self.lyricLabel.alpha = model.isActiveLine ? 1 : 0.32 }
    if animated, !UIAccessibility.isReduceMotionEnabled {
      UIView.animate(withDuration: 0.3, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
    } else { changes() }
  }
}
