//
//  SsPlaylistsParserTest.swift
//  AmperfyKitTests
//
//  Created by Maximilian Bauer on 01.06.21.
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

class SsPlaylistsParserTest: AbstractSsParserTest {
  override func setUp() async throws {
    try await super.setUp()
    xmlData = getTestFileData(name: "playlists_example_1")
  }

  override func createParserDelegate() {
    ssParserDelegate = SsPlaylistParserDelegate(
      performanceMonitor: MOCK_PerformanceMonitor(), account: account,
      library: library
    )
  }

  func testServerCoverReplacementRemovalAndAccountIsolation() throws {
    func parseCover(_ attribute: String, for targetAccount: Account) {
      let delegate = SsPlaylistParserDelegate(
        performanceMonitor: MOCK_PerformanceMonitor(), account: targetAccount, library: library
      )
      let xml = "<playlists><playlist id=\"15\" name=\"Test\" \(attribute)/></playlists>"
      let parser = XMLParser(data: Data(xml.utf8))
      parser.delegate = delegate
      XCTAssertTrue(parser.parse())
    }

    parseCover("coverArt=\"pl-15_hash1\"", for: account)
    let playlist = try XCTUnwrap(library.getPlaylist(for: account, id: "15"))
    let original = try XCTUnwrap(playlist.artwork)
    XCTAssertEqual(playlist.getArtworkCollection(theme: .blue).serverArtwork, original)
    parseCover("coverArt=\"pl-15_hash1\"", for: account)
    XCTAssertEqual(playlist.artwork, original)

    let secondAccount = library.getAccount(info: TestAccountInfo.create2())
    parseCover("coverArt=\"pl-15_hash1\"", for: secondAccount)
    let otherPlaylist = try XCTUnwrap(library.getPlaylist(for: secondAccount, id: "15"))
    XCTAssertNotEqual(otherPlaylist.artwork, original)
    XCTAssertEqual(otherPlaylist.artwork?.account?.info, secondAccount.info)

    parseCover("coverArt=\"pl-15_hash2\"", for: account)
    XCTAssertEqual(playlist.artwork?.id, "pl-15_hash2")
    XCTAssertNotEqual(playlist.artwork, original)
    parseCover("", for: account)
    XCTAssertNil(playlist.artwork)
    XCTAssertNil(playlist.getArtworkCollection(theme: .blue).serverArtwork)
    XCTAssertEqual(otherPlaylist.artwork?.id, "pl-15_hash1")
  }

  func testLibraryContainsBeforeMorePlaylistsThenAfter() {
    for i in 20 ... 30 {
      let playlist = library.createPlaylist(account: account)
      playlist.id = i.description
      playlist.name = i.description
    }
    testParsing()
  }

  override func checkCorrectParsing() {
    let playlists = library.getPlaylists(for: account)
    XCTAssertEqual(playlists.count, 2)

    var playlist = playlists[1]
    XCTAssertEqual(playlist.account?.serverHash, TestAccountInfo.test1ServerHash)
    XCTAssertEqual(playlist.account?.userHash, TestAccountInfo.test1UserHash)
    XCTAssertEqual(playlist.id, "15")
    XCTAssertEqual(playlist.artwork?.id, "pl-15")
    XCTAssertEqual(playlist.artwork?.account?.info, account.info)
    XCTAssertEqual(playlist.name, "Some random songs")
    XCTAssertEqual(playlist.songCount, 6)
    XCTAssertEqual(playlist.remoteSongCount, 6)
    XCTAssertEqual(playlist.duration, 1391)
    XCTAssertEqual(playlist.remoteDuration, 1391)
    XCTAssertFalse(playlist.isCached)

    playlist = playlists[0]
    XCTAssertEqual(playlist.account?.serverHash, TestAccountInfo.test1ServerHash)
    XCTAssertEqual(playlist.account?.userHash, TestAccountInfo.test1UserHash)
    XCTAssertEqual(playlist.id, "16")
    XCTAssertEqual(playlist.artwork?.id, "pl-16")
    XCTAssertEqual(playlist.name, "More random songs")
    XCTAssertEqual(playlist.songCount, 5)
    XCTAssertEqual(playlist.remoteSongCount, 5)
    XCTAssertEqual(playlist.duration, 1018)
    XCTAssertEqual(playlist.remoteDuration, 1018)
    XCTAssertFalse(playlist.isCached)
  }
}
