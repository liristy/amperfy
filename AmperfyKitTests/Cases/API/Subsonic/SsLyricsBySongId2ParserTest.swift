//
//  SsLyricsBySongId2ParserTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 16.06.24.
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
import CoreMedia

class SsLyricsBySongId2ParserTest: AbstractSsParserTest {
  override func setUp() async throws {
    try await super.setUp()
    xmlData = getTestFileData(name: "getLyricsBySongId_example_2")
    ssParserDelegate = SsLyricsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
  }

  override func createParserDelegate() {
    ssParserDelegate = SsLyricsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
  }

  private func parseLyrics(_ xml: String) throws -> [StructuredLyrics] {
    let delegate = SsLyricsParserDelegate(performanceMonitor: MOCK_PerformanceMonitor())
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = delegate
    XCTAssertTrue(parser.parse())
    return try XCTUnwrap(delegate.lyricsList?.lyrics)
  }

  func testEnhancedLyricsUseInclusiveUTF8Offsets() throws {
    let lyrics = try parseLyrics("""
    <lyricsList>
      <structuredLyrics lang="zh" synced="true" kind="translation">
        <line start="1000">翻译</line>
      </structuredLyrics>
      <structuredLyrics lang="zh" synced="true" kind="main" offset="100">
        <line start="1050">你 love love 😀</line>
        <line start="3000">No word timings</line>
        <cueLine index="0" value="你 love love 😀">
          <cue start="1000" end="1200" byteStart="0" byteEnd="2">你</cue>
          <cue start="1350" end="1800" byteStart="9" byteEnd="12">love</cue>
          <cue start="2000" end="2500" byteStart="14" byteEnd="17">😀</cue>
          <cue start="2700" byteStart="1" byteEnd="2">Invalid UTF-8 boundary</cue>
        </cueLine>
      </structuredLyrics>
    </lyricsList>
    """)
    XCTAssertEqual(lyrics.count, 1)
    let main = try XCTUnwrap(lyrics.first)
    let line = try XCTUnwrap(main.line.first)
    XCTAssertEqual(line.start, 1000)
    XCTAssertEqual(line.value, "你 love love 😀")
    XCTAssertEqual(line.cues.map(\.start), [1000, 1350, 2000])
    XCTAssertEqual(line.cues.map(\.end), [1200, 1800, 2500])
    XCTAssertEqual(line.cues.map(\.range), [
      NSRange(location: 0, length: 1),
      NSRange(location: 7, length: 4),
      NSRange(location: 12, length: 2),
    ])
    XCTAssertTrue(main.line.last?.cues.isEmpty == true)
    let time = CMTime(value: 1250, timescale: 1000)
    XCTAssertEqual(main.adjustedTime(for: time), CMTime(value: 1350, timescale: 1000))
  }

  func testInlineEnhancedLRCKeepsTextAndTrailingEndTime() throws {
    let lyrics = try parseLyrics("""
    <lyricsList>
      <structuredLyrics synced="true">
        <line start="1000">你&lt;00:01.25&gt;好&lt;00:01.750&gt;</line>
        <line start="2000"><value><![CDATA[<00:02.0>Sing <00:02.36>along]]></value></line>
      </structuredLyrics>
    </lyricsList>
    """)
    let lines = try XCTUnwrap(lyrics.first?.line)
    XCTAssertEqual(lines.map(\.value), ["你好", "Sing along"])
    XCTAssertEqual(lines.first?.cues.map(\.start), [1000, 1250])
    XCTAssertEqual(lines.first?.cues.map(\.end), [1250, 1750])
    XCTAssertEqual(lines.last?.cues.map(\.start), [2000, 2360])
    XCTAssertEqual(lines.last?.cues.map(\.range), [
      NSRange(location: 0, length: 5), NSRange(location: 5, length: 5),
    ])
  }

  func testActiveLineAtBoundariesAndAfterFinalLine() {
    var lyrics = StructuredLyrics()
    lyrics.synced = true
    lyrics.line = [1000, 2000, 3000].map { start in
      var line = LyricsLine()
      line.start = start
      line.value = "Line"
      return line
    }
    func time(_ milliseconds: Int64) -> CMTime { CMTime(value: milliseconds, timescale: 1000) }
    XCTAssertNil(lyrics.activeLineIndex(at: time(999)))
    XCTAssertEqual(lyrics.activeLineIndex(at: time(1000)), 0)
    XCTAssertEqual(lyrics.activeLineIndex(at: time(1999)), 0)
    XCTAssertEqual(lyrics.activeLineIndex(at: time(2000)), 1)
    XCTAssertEqual(lyrics.activeLineIndex(at: time(3000)), 2)
    XCTAssertEqual(lyrics.activeLineIndex(at: time(60000)), 2)
    lyrics.offset = 100
    XCTAssertEqual(lyrics.activeLineIndex(at: time(1900)), 1)
    lyrics.offset = -100
    XCTAssertEqual(lyrics.activeLineIndex(at: time(2000)), 0)
    lyrics.synced = false
    XCTAssertNil(lyrics.activeLineIndex(at: time(2000)))
  }

  func testExactMillisecondSeekBoundariesWithPositiveAndNegativeOffsets() {
    var lyrics = StructuredLyrics()
    lyrics.synced = true
    lyrics.line = [0, 1001, 16013, 32003, 65001].map { start in
      var line = LyricsLine()
      line.start = start
      return line
    }
    for offset in [-125, 0, 250] {
      lyrics.offset = offset
      for index in 1..<lyrics.line.count {
        let time = CMTime(value: Int64(lyrics.line[index].start! - offset), timescale: 1000)
        XCTAssertEqual(lyrics.activeLineIndex(at: time), index)
        XCTAssertEqual(lyrics.activeLineIndex(at: CMTimeSubtract(time, CMTime(value: 1, timescale: 1000))), index-1)
      }
    }
  }

  override func checkCorrectParsing() {
    guard let lyricsParser = ssParserDelegate as? SsLyricsParserDelegate,
          let lyricsList = lyricsParser.lyricsList
    else {
      XCTFail()
      return
    }
    prefetchIdTester.checkPrefetchIdCounts()

    XCTAssertEqual(lyricsList.lyrics.count, 2)

    var structuredLyrics = lyricsList.lyrics[0]
    XCTAssertEqual(structuredLyrics.displayArtist, "Muse")
    XCTAssertEqual(structuredLyrics.displayTitle, "Hysteria")
    XCTAssertEqual(structuredLyrics.lang, "en")
    XCTAssertEqual(structuredLyrics.offset, -100)
    XCTAssertTrue(structuredLyrics.synced)
    XCTAssertEqual(structuredLyrics.line.count, 3)
    XCTAssertEqual(structuredLyrics.line[0].start, 0)
    XCTAssertEqual(structuredLyrics.line[0].value, "It's bugging me")
    XCTAssertEqual(structuredLyrics.line[1].start, 2000)
    XCTAssertEqual(structuredLyrics.line[1].value, "Grating me")
    XCTAssertEqual(structuredLyrics.line[2].start, 3001)
    XCTAssertEqual(structuredLyrics.line[2].value, "And twisting me around...")

    structuredLyrics = lyricsList.lyrics[1]
    XCTAssertEqual(structuredLyrics.displayArtist, "Mu2se")
    XCTAssertEqual(structuredLyrics.displayTitle, "Hy2steria")
    XCTAssertEqual(structuredLyrics.lang, "de")
    XCTAssertEqual(structuredLyrics.offset, 100)
    XCTAssertFalse(structuredLyrics.synced)
    XCTAssertEqual(structuredLyrics.line.count, 3)
    XCTAssertEqual(structuredLyrics.line[0].start, nil)
    XCTAssertEqual(structuredLyrics.line[0].value, "It's bugging2 me")
    XCTAssertEqual(structuredLyrics.line[1].start, nil)
    XCTAssertEqual(structuredLyrics.line[1].value, "Grating2 me")
    XCTAssertEqual(structuredLyrics.line[2].start, nil)
    XCTAssertEqual(structuredLyrics.line[2].value, "And twisting2 me around...")
  }
}
