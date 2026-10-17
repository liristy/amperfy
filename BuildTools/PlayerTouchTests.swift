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
    low.press(forDuration: 0.05,
      thenDragTo: lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.1)
    expectControls("shown")
    lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
      .press(forDuration: 0.05, thenDragTo: lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
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
