//
//  ContextQueuePrevSectionHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 22.11.21.
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

import MarqueeLabel
import UIKit

class ContextQueuePrevSectionHeader: UIView {
  var onClear: (() -> Void)? {
    didSet { clearButton.isHidden = onClear == nil }
  }
  private let clearButton = UIButton(type: .system)
  @IBOutlet
  weak var nameLabel: MarqueeLabel!

  static let frameHeight: CGFloat = 20.5 + margin.top + margin.bottom
  static let margin = UIEdgeInsets(
    top: 8,
    left: UIView.defaultMarginX,
    bottom: 8,
    right: UIView.defaultMarginX
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
  }

  func display(name: String) {
    backgroundColor = .clear
    isOpaque = false
    nameLabel.backgroundColor = .clear
    nameLabel.text = name
    nameLabel.isHidden = name.isEmpty
    nameLabel.applyAmperfyStyle()
    if clearButton.superview == nil {
      NSLayoutConstraint.deactivate(constraints)
      nameLabel.translatesAutoresizingMaskIntoConstraints = true
      clearButton.setTitle("Clear".localized, for: .normal)
      clearButton.tintColor = .white.withAlphaComponent(0.65)
      clearButton.titleLabel?.font = .systemFont(ofSize: 15)
      clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
      addSubview(clearButton)
      clearButton.isHidden = onClear == nil
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    nameLabel.frame = CGRect(x: 8, y: 8, width: max(0, bounds.width - 100), height: 22)
    clearButton.frame = CGRect(x: bounds.width - 76, y: 0, width: 68, height: Self.frameHeight)
  }
}
