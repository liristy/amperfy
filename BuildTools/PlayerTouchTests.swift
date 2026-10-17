import XCTest

final class PlayerTouchTests: XCTestCase {
  func testActualFingerDragging() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "de.familie-zimba.amperfy-music")
    app.activate()
    let slider = app.descendants(matching: .any)["player.playbackPosition"]
    XCTAssertTrue(slider.waitForExistence(timeout: 30))
    let finish = app.buttons["player.finishTouchTest"]
    XCTAssertTrue(finish.waitForExistence(timeout: 30))
    let middle = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let right = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
    let left = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
    // XCTest injects actual touchscreen events, including a held native control.
    middle.press(forDuration: 0.4, thenDragTo: right, withVelocity: .slow,
      thenHoldForDuration: 0.4)
    right.press(forDuration: 0.2, thenDragTo: left, withVelocity: .slow,
      thenHoldForDuration: 0.4)
    left.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .fast,
      thenHoldForDuration: 0.05)
    middle.press(forDuration: 0.05, thenDragTo: right, withVelocity: .fast,
      thenHoldForDuration: 0.05)
    let outside = right.withOffset(CGVector(dx: 0, dy: 60))
    middle.press(forDuration: 0.2, thenDragTo: outside, withVelocity: .slow,
      thenHoldForDuration: 0.2)
    // Holding alone must expand without moving the playback position.
    middle.press(forDuration: 0.5)
    finish.tap()

    // Continue the same real-touch session when the player reaches immersive lyrics.
    let lyricsFinish = app.buttons["player.finishLyricsTouchTest"]
    XCTAssertTrue(lyricsFinish.waitForExistence(timeout: 120))
    let lyrics = app.tables["player.lyricsTable"]
    XCTAssertTrue(lyrics.exists)
    func expectControls(_ value: String) {
      let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: lyricsFinish)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }
    expectControls("hidden")
    let low = lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
    low.tap()
    expectControls("hidden")
    lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
      .press(forDuration: 0.05, thenDragTo: lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
        withVelocity: .slow, thenHoldForDuration: 0.1)
    expectControls("shown")
    lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
      .press(forDuration: 0.05, thenDragTo: lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)),
        withVelocity: .slow, thenHoldForDuration: 0.1)
    expectControls("hidden")
    let tableFrame = lyrics.frame
    // Lyric cells expose the static-text trait to VoiceOver and XCTest.
    let candidates = lyrics.staticTexts.allElementsBoundByIndex.filter {
      $0.isHittable && $0.frame.midY > tableFrame.minY + 80 && $0.frame.midY < tableFrame.maxY - 80
    }
    XCTAssertFalse(candidates.isEmpty, lyrics.debugDescription)
    candidates.first?.tap()
    expectControls("hidden")
    lyricsFinish.tap()
  }
}

extension PlayerTouchTests {
  func testLyricsArtworkRegionHorizontalDrags() throws {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "de.familie-zimba.amperfy-music")
    for baseline in [true, false] {
      app.launchArguments = ["--smoke-login", "--smoke-lyrics-gesture", "-AppleLanguages", "(zh-Hans)"] +
        (baseline ? ["--lyrics-gesture-baseline"] : [])
      app.launch()
      let probe = app.descendants(matching: .any)["player.lyricsGestureProbe"]
      XCTAssertTrue(probe.waitForExistence(timeout: 70))
      func snapshot() throws -> [String: Any] {
        let value = try XCTUnwrap(probe.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
      }
      let before = try snapshot()
      XCTAssertTrue((before["hitPath"] as? [String])?.contains("LyricsView") == true,
        "The staged artwork-region coordinates hit controls instead of lyrics: \(before)")
      let region = try XCTUnwrap(before["region"] as? [Double])
      let origin = app.coordinate(withNormalizedOffset: .zero)
      func point(_ x: Double, _ y: Double) -> XCUICoordinate {
        origin.withOffset(CGVector(dx: region[0] + region[2] * x, dy: region[1] + region[3] * y))
      }
      let started = Date()
      // These coordinates come from the actual large artwork before entering
      // lyrics, intersected with the visible lyric table. Never swipe the dock.
      for y in [0.25, 0.65] {
        point(0.15, y).press(forDuration: 0.02, thenDragTo: point(0.85, y), withVelocity: .fast, thenHoldForDuration: 0)
        point(0.85, y).press(forDuration: 0.02, thenDragTo: point(0.15, y), withVelocity: .slow, thenHoldForDuration: 0)
      }
      let after = try snapshot()
      print("LYRICS_GESTURE \(baseline ? "baseline" : "fixed") before=\(before) after=\(after)")
      if !baseline {
        XCTAssertEqual(after["song"] as? String, before["song"] as? String)
        XCTAssertEqual(after["selections"] as? Int, before["selections"] as? Int, "Horizontal drag selected a lyric")
        XCTAssertGreaterThan(try XCTUnwrap(after["blocked"] as? Int), 0)
        let elapsed = try XCTUnwrap(after["elapsed"] as? Double) - XCTUnwrap(before["elapsed"] as? Double)
        XCTAssertEqual(elapsed, Date().timeIntervalSince(started), accuracy: 3, "Horizontal drag sought through the song")
        XCTAssertEqual(try XCTUnwrap(after["offsetX"] as? Double), 0, accuracy: 0.5)
        let drags = try XCTUnwrap(after["drags"] as? Int)
        point(0.5, 0.85).press(forDuration: 0.02, thenDragTo: point(0.5, 0.2), withVelocity: .fast, thenHoldForDuration: 0)
        point(0.5, 0.85).press(forDuration: 0.02, thenDragTo: point(0.5, 0.2), withVelocity: .fast, thenHoldForDuration: 0)
        let scrolled = try snapshot()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(scrolled["drags"] as? Int), drags + 2, "Second flick did not begin")
        XCTAssertGreaterThan(try XCTUnwrap(scrolled["offsetY"] as? Double), try XCTUnwrap(after["offsetY"] as? Double) + 30)
        let lyrics = app.tables["player.lyricsTable"]
        let frame = lyrics.frame
        let row = lyrics.staticTexts.allElementsBoundByIndex.first {
          $0.isHittable && $0.frame.midY > frame.minY + 40 && $0.frame.midY < frame.maxY - 40
        }
        XCTAssertNotNil(row)
        let count = try XCTUnwrap(scrolled["selections"] as? Int)
        row?.tap()
        XCTAssertEqual(try XCTUnwrap(try snapshot()["selections"] as? Int), count + 1, "Deliberate lyric tap stopped working")
        print("LYRICS_GESTURE repeated-scroll=\(scrolled) tapped=\(try snapshot())")
      }
      app.terminate()
    }
  }
}
