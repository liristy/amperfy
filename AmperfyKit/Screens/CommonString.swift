//
//  CommonString.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 06.06.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
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

import Foundation

public class CommonString {
  public static func count(_ value: Int, singular: String, plural: String) -> String {
    (value == 1 ? singular : plural).localizedFormat(value)
  }

  public static func songs(_ value: Int) -> String {
    count(value, singular: "%ld Song", plural: "%ld Songs")
  }

  public static func albums(_ value: Int) -> String {
    count(value, singular: "%ld Album", plural: "%ld Albums")
  }

  public static func artists(_ value: Int) -> String {
    count(value, singular: "%ld Artist", plural: "%ld Artists")
  }

  public static func episodes(_ value: Int) -> String {
    count(value, singular: "%ld Episode", plural: "%ld Episodes")
  }

  public static func radios(_ value: Int) -> String {
    count(value, singular: "%ld Radio", plural: "%ld Radios")
  }

  public static let oneMiddleDot: String = "\u{00B7}"
  public static let threeMiddleDots: String =
    "\u{00B7}\u{00B7}\u{00B7}" // ellipsis vertically centered
  public static let ellipsis: String = "\u{2026}" // ellipsis
}

extension String {
  public func localizedFormat(_ arguments: CVarArg...) -> String {
    String(format: localized, locale: Locale.current, arguments: arguments)
  }

  /// Localizes interface text while leaving server-provided music metadata unchanged.
  public var localized: String {
    NSLocalizedString(self, bundle: .main, comment: "")
  }
}
