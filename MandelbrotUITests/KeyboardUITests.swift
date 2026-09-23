import XCTest

#if os(iOS)
  /// An iPad with a hardware keyboard: the menu's shortcuts are its only key
  /// route, so the bare keys must be bound there, and a text field in a sheet
  /// must still get its own arrows.  Stage 5 of 2.12 broke the first.
  final class KeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
      continueAfterFailure = false
      try XCTSkipUnless(
        UIDevice.current.userInterfaceIdiom == .pad, "Hardware-keyboard commands are an iPad matter"
      )
    }

    @MainActor func testBareKeysReachTheCanvasButNotASheetsTextField() throws {
      let app = XCUIApplication()
      app.launch()
      let canvas = app.otherElements["viewerCanvas"]
      XCTAssertTrue(canvas.waitForExistence(timeout: 10))

      // Home, then in far enough that a small pan changes the place's name.
      app.typeKey("0", modifierFlags: .command)
      for _ in 0..<3 { app.typeKey("+", modifierFlags: .command) }
      let zoomed = try XCTUnwrap(canvas.value as? String)
      XCTAssertTrue(zoomed.hasSuffix("8×"), "⌘+ did not zoom: \(zoomed)")

      app.typeKey(.rightArrow, modifierFlags: [])
      let moved = try XCTUnwrap(canvas.value as? String)
      XCTAssertNotEqual(moved, zoomed, "A bare arrow did not move the view")

      // In a sheet's text field the arrows are the field's.
      app.typeKey("l", modifierFlags: .command)
      let field = app.textFields.firstMatch
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.tap()
      field.typeText("ab")
      app.typeKey(.leftArrow, modifierFlags: [])
      field.typeText("c")
      XCTAssertEqual(field.value as? String, "acb", "The arrow did not move the text cursor")
      app.buttons["Done"].tap()
      XCTAssertEqual(canvas.value as? String, moved, "An arrow in the text field moved the view")

      // ? is Shift-/ on the keyboard, and opens Controls.
      app.typeKey("/", modifierFlags: .shift)
      XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
    }
  }
#endif
