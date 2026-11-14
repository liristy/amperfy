//
//  UtilitiesTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 09.05.21.
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

@testable import AmperfyKit
import XCTest
import UIKit

class UtilitiesTest: XCTestCase {
  @MainActor
  func testArtworkPalettePreservesDominantRegionsAndIgnoresTransparency() throws {
    let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 384, height: 512))
      UIColor.blue.setFill()
      context.fill(CGRect(x: 384, y: 0, width: 128, height: 512))
    }
    let colors = image.boundedArtworkPalette()
    XCTAssertEqual(colors.count, 2)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    try XCTUnwrap(colors.first).getRed(&r, green: &g, blue: &b, alpha: &a)
    XCTAssertGreaterThan(r, 0.9)
    XCTAssertLessThan(b, 0.1)
    let transparent = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in }
    XCTAssertTrue(transparent.boundedArtworkPalette().isEmpty)
    XCTAssertTrue(UIImage().boundedArtworkPalette().isEmpty)
  }

  @MainActor
  func testComplexArtworkPaletteHasBoundedRuntime() throws {
    let side = 1200
    var pixels = [UInt8](repeating: 255, count: side * side * 4)
    var seed: UInt32 = 42
    for i in stride(from: 0, to: pixels.count, by: 4) {
      seed = seed &* 1664525 &+ 1013904223
      pixels[i] = UInt8(truncatingIfNeeded: seed >> 24)
      pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 16)
      pixels[i + 2] = UInt8(truncatingIfNeeded: seed >> 8)
    }
    let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
    let cgImage = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8,
      bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let image = UIImage(cgImage: cgImage)
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<20 { XCTAssertEqual(image.boundedArtworkPalette().count, 2) }
    // Loose CI ceiling catches the original multi-second clustering failure.
    XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 5)
  }

  func testInt16Valid() {
    XCTAssertTrue(Int16.isValid(value: Int(Int16.max)))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.min)))
    XCTAssertTrue(Int16.isValid(value: Int(0)))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.min) + 1))
    XCTAssertTrue(Int16.isValid(value: Int(Int16.max) - 1))
  }

  func testInt16Invalid() {
    XCTAssertFalse(Int16.isValid(value: Int(Int16.max) + 1))
    XCTAssertFalse(Int16.isValid(value: Int(Int16.min) - 1))
    XCTAssertFalse(Int16.isValid(value: Int(Int32.min)))
    XCTAssertFalse(Int16.isValid(value: Int(Int32.max)))
  }

  func testInt32Valid() {
    XCTAssertTrue(Int32.isValid(value: Int(Int32.max)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.min)))
    XCTAssertTrue(Int32.isValid(value: Int(0)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.min + 1)))
    XCTAssertTrue(Int32.isValid(value: Int(Int32.max - 1)))
  }

  func testInt32Invalid() {
    XCTAssertFalse(Int32.isValid(value: Int(Int32.max) + 1))
    XCTAssertFalse(Int32.isValid(value: Int(Int32.min) - 1))
    XCTAssertFalse(Int32.isValid(value: Int(Int64.min)))
    XCTAssertFalse(Int32.isValid(value: Int(Int64.max)))
  }
}
