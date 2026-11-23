//
//  SsLyricsParserDelegate.swift
//  AmperfyKit
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

import Foundation

class SsLyricsParserDelegate: SsXmlParser {
  private struct CueLine {
    let index: Int
    let value: String
    let start: Int?
    let end: Int?
    let agentID: String?
    var cues = [LyricCue]()

    mutating func appendCue(attributes: [String: String]) {
      let utf8 = value.utf8
      let utf16 = value.utf16
      guard let start = attributes["start"].flatMap(Int.init), start >= 0,
            let firstByte = attributes["byteStart"].flatMap(Int.init),
            let lastByte = attributes["byteEnd"].flatMap(Int.init),
            firstByte >= 0, firstByte <= lastByte, lastByte < utf8.count,
            let lower = utf8.index(utf8.startIndex, offsetBy: firstByte).samePosition(in: utf16),
            let upper = utf8.index(utf8.startIndex, offsetBy: lastByte + 1).samePosition(in: utf16)
      else { return }

      let end = attributes["end"].flatMap(Int.init)
      guard end.map({ $0 >= start }) ?? true else { return }
      let range = NSRange(location: utf16.distance(from: utf16.startIndex, to: lower),
                          length: utf16.distance(from: lower, to: upper))
      cues.append(LyricCue(start: start, end: end, range: range))
    }
  }

  public var lyricsList: LyricsList?
  private var structuredLyrics: StructuredLyrics?
  private var kind: String?
  private var lines: [LyricsLine]?
  private var currentLine: LyricsLine?
  private var cueLines = [Int: [CueLine]]()
  private var currentCueLine: CueLine?

  override func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String]
  ) {
    super.parser(
      parser,
      didStartElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName,
      attributes: attributeDict
    )

    if elementName == "lyricsList" {
      lyricsList = LyricsList()
      structuredLyrics = nil
      lines = nil
      currentLine = nil
    } else if elementName == "structuredLyrics" {
      structuredLyrics = StructuredLyrics()
      kind = attributeDict["kind"]
      cueLines.removeAll()
      currentCueLine = nil
      structuredLyrics?.displayArtist = attributeDict["displayArtist"]
      structuredLyrics?.displayTitle = attributeDict["displayTitle"]
      structuredLyrics?.lang = attributeDict["lang"] ?? ""
      if let offsetStr = attributeDict["offset"], let offsetInt = Int(offsetStr) {
        structuredLyrics?.offset = offsetInt
      } else {
        structuredLyrics?.offset = 0
      }

      if let isSynced = attributeDict["synced"] {
        structuredLyrics?.synced = (isSynced == "true")
      } else {
        structuredLyrics?.synced = false
      }
      lines = [LyricsLine]()
      currentLine = nil
    } else if elementName == "line" {
      currentLine = LyricsLine()
      if let startStr = attributeDict["start"], let startInt = Int(startStr) {
        currentLine?.start = startInt
      }
    } else if elementName == "cueLine" {
      if let index = attributeDict["index"].flatMap(Int.init),
         let value = attributeDict["value"] {
        currentCueLine = CueLine(
          index: index, value: value,
          start: attributeDict["start"].flatMap(Int.init),
          end: attributeDict["end"].flatMap(Int.init),
          agentID: attributeDict["agentId"]
        )
      }
    } else if elementName == "cue" {
      currentCueLine?.appendCue(attributes: attributeDict)
    }
  }

  @objc func parser(_ parser: XMLParser, foundCDATA data: Data) {
    if let text = String(data: data, encoding: .utf8) { buffer.append(text) }
  }

  override func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    if elementName == "line" || elementName == "value", var curLine = currentLine {
      curLine.value = buffer
      lines?.append(curLine)
      currentLine = nil
    } else if elementName == "cueLine", let currentCueLine {
      cueLines[currentCueLine.index, default: []].append(currentCueLine)
      self.currentCueLine = nil
    } else if elementName == "structuredLyrics", var curStructuredLyrics = structuredLyrics {
      let synced = curStructuredLyrics.synced
      curStructuredLyrics.line = (lines ?? []).enumerated().map { index, line in
        var lyric = synced ? timedLine(line, cueLines: cueLines[index] ?? []) : line
        if !synced { lyric.parseInlineTranslation() }
        return lyric
      }
      if kind == "translation" {
        lyricsList?.translations.append(curStructuredLyrics)
      } else if kind == nil || kind == "" || kind == "main" {
        lyricsList?.lyrics.append(curStructuredLyrics)
      }
      structuredLyrics = nil
      lines = nil
    }

    super.parser(
      parser,
      didEndElement: elementName,
      namespaceURI: namespaceURI,
      qualifiedName: qName
    )
  }

  private func timedLine(_ line: LyricsLine, cueLines: [CueLine]) -> LyricsLine {
    var line = line
    // Some servers return a line-only cueLine alongside intact inline ELRC.
    // Parse the line first so that the cueLine cannot hide its word timings.
    line.parseEnhancedLRC()
    line.parseInlineTranslation()
    let inlineLyrics = line
    line.vocals = cueLines.compactMap { cueLine in
      var vocal = LyricsLine()
      vocal.value = cueLine.value
      vocal.start = cueLine.start ?? inlineLyrics.start
      vocal.cues = cueLine.cues
      if vocal.cues.isEmpty { vocal.parseEnhancedLRC() }
      vocal.parseInlineTranslation()
      guard !vocal.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      if vocal.cues.isEmpty, vocal.value.utf8.elementsEqual(inlineLyrics.value.utf8) {
        vocal.cues = inlineLyrics.cues
      }
      let cues = vocal.cues
      let start = [vocal.start, cues.map(\.start).min()].compactMap { $0 }.min()
      let end = [cueLine.end, cues.last?.end].compactMap { $0 }.max()
      return LyricVocal(value: vocal.value, start: start, end: end, cues: cues, agentID: cueLine.agentID)
    }
    if !line.cues.isEmpty, !line.vocals.contains(where: { !$0.cues.isEmpty }) {
      line.vocals.removeAll()
    }
    let matchingVocal = line.vocals.first {
      $0.value.utf8.elementsEqual(inlineLyrics.value.utf8) && !$0.cues.isEmpty
    }
    if let vocal = line.vocals.count == 1 ? line.vocals.first : matchingVocal, !vocal.cues.isEmpty {
      line.value = vocal.value
      line.cues = vocal.cues
    }
    if let firstCueStart = (line.cues.map(\.start) + line.vocals.compactMap(\.start)).min() {
      line.start = min(line.start ?? firstCueStart, firstCueStart)
    }
    return line
  }
}

private extension LyricsLine {
  mutating func parseInlineTranslation() {
    let parts = value.components(separatedBy: "_BREAK_")
    guard parts.count > 1 else { return }
    value = parts[0]
    let length = value.utf16.count
    cues = cues.compactMap { cue in
      let end = min(NSMaxRange(cue.range), length)
      guard cue.range.location < end else { return nil }
      return LyricCue(start: cue.start, end: cue.end,
        range: NSRange(location: cue.range.location, length: end - cue.range.location))
    }
    let text = parts.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text != value.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
    translation = LyricVocal(value: text, start: nil, end: nil, cues: [], agentID: nil)
  }

  static let wordTimestamp = try! NSRegularExpression(
    pattern: #"<(?:([0-9]{1,3}):)?([0-9]{1,6}):([0-5][0-9])(?:[.:]([0-9]{1,3}))?>"#
  )

  mutating func parseEnhancedLRC() {
    let source = value as NSString
    let timestamps = Self.wordTimestamp.matches(in: value, range: NSRange(location: 0, length: source.length))
    guard !timestamps.isEmpty else { return }
    var text = ""
    var textLength = 0
    var position = 0
    var cueStart = start

    func appendText(until end: Int, cueEnd: Int?) {
      let segment = source.substring(with: NSRange(location: position, length: end - position))
      let length = end - position
      if let cueStart, !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let range = NSRange(location: textLength, length: length)
        let endTime = cueEnd.flatMap { $0 >= cueStart ? $0 : nil }
        cues.append(LyricCue(start: cueStart, end: endTime, range: range))
      }
      text.append(segment)
      textLength += length
    }

    for timestamp in timestamps {
      func group(_ index: Int) -> String {
        let range = timestamp.range(at: index)
        return range.location == NSNotFound ? "" : source.substring(with: range)
      }
      let hours = Int(group(1)) ?? 0
      guard let minutes = Int(group(2)), let seconds = Int(group(3)) else { continue }
      let fraction = group(4).padding(toLength: 3, withPad: "0", startingAt: 0)
      let milliseconds = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + (Int(fraction) ?? 0)
      appendText(until: timestamp.range.location, cueEnd: milliseconds)
      cueStart = milliseconds
      position = NSMaxRange(timestamp.range)
    }
    appendText(until: source.length, cueEnd: nil)
    value = text
  }
}
