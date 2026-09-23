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
      // Each key is followed by a wait for the view to answer it: reading the
      // value straight after a key press raced the update and was flaky.
      app.typeKey("0", modifierFlags: .command)
      for _ in 0..<3 { app.typeKey("+", modifierFlags: .command) }
      XCTAssertTrue(
        wait(for: canvas, until: { $0.hasSuffix("8×") }), "⌘+ did not zoom: \(value(canvas))")
      let zoomed = value(canvas)

      app.typeKey(.rightArrow, modifierFlags: [])
      XCTAssertTrue(
        wait(for: canvas, until: { $0 != zoomed }), "A bare arrow did not move the view")
      let moved = value(canvas)

      // In a sheet's text field the arrows are the field's.
      app.typeKey("l", modifierFlags: .command)
      // Under load the sheet is still settling when its field first appears,
      // and a tap then finds nothing: wait for the sheet, then for the field
      // to take a tap.
      XCTAssertTrue(
        app.navigationBars["Places"].waitForExistence(timeout: 10), "Places did not open")
      let field = app.textFields.firstMatch
      let settled = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND hittable == true"), object: field)
      XCTAssertEqual(
        XCTWaiter().wait(for: [settled], timeout: 10), .completed, "Places closed again")
      field.tap()
      field.typeText("ab")
      app.typeKey(.leftArrow, modifierFlags: [])
      field.typeText("c")
      XCTAssertTrue(
        wait(for: field, until: { $0 == "acb" }),
        "The arrow did not move the text cursor: \(value(field))")
      app.buttons["Done"].tap()
      XCTAssertTrue(canvas.waitForExistence(timeout: 5))
      XCTAssertEqual(value(canvas), moved, "An arrow in the text field moved the view")

      // ? is Shift-/ on the keyboard, and opens Controls.
      app.typeKey("/", modifierFlags: .shift)
      XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Waits up to five seconds for an element's value to satisfy a test.
    private func wait(for element: XCUIElement, until test: @escaping (String) -> Bool) -> Bool {
      let predicate = NSPredicate { object, _ in
        test((object as? XCUIElement)?.value as? String ?? "")
      }
      let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
      return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
  }
#endif
