import XCTest

final class PlayerTouchTests: XCTestCase {
  func testActualFingerDragging() {
    continueAfterFailure = false
    let app = XCUIApplication(bundleIdentifier: "de.familie-zimba.amperfy-music")
    app.activate()
    let slider = app.sliders["player.playbackPosition"]
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
  }
}
