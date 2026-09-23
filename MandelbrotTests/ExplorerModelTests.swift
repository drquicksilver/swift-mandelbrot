import Foundation
import Testing

@testable import Mandelbrot

/// Defaults held in memory.  The test host shares the app's bundle
/// identifier, so `.standard` is the real app's preferences, and even a
/// removed suite leaves an empty file in ~/Library/Preferences.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
  private var values: [String: Any] = [:]
  init() { super.init(suiteName: nil)! }
  override func object(forKey key: String) -> Any? { values[key] }
  override func set(_ value: Any?, forKey key: String) { values[key] = value }
  override func removeObject(forKey key: String) { values[key] = nil }
}

/// The model's rules for menus, travel and remembering where you were.
@MainActor struct ExplorerModelTests {
  let defaults = MemoryDefaults()
  func model() -> ExplorerModel {
    ExplorerModel(bookmarks: LocationStore(defaults: defaults), defaults: defaults)
  }
  let seahorse = Location.gallery[1]

  // MARK: Menu validation

  @Test func backAndForwardFollowTheHistory() {
    let model = model()
    #expect(!model.canPerform(.back) && !model.canPerform(.forward))
    model.perform(.zoomIn)
    #expect(model.canPerform(.back) && !model.canPerform(.forward))
    model.perform(.back)
    #expect(model.canPerform(.forward))
  }

  @Test func swapAndUprightOnlyWhenTheyWouldDoSomething() {
    let model = model()
    #expect(!model.canPerform(.swapJulia))
    model.toggleJulia()
    #expect(model.canPerform(.swapJulia))
    #expect(!model.canPerform(.resetRotation))
    model.perform(.rotateLeft)
    #expect(model.canPerform(.resetRotation))
  }

  @Test func nothingActsBehindASheet() {
    let sheets: [ReferenceWritableKeyPath<ExplorerModel, Bool>] = [
      \.showPlaces, \.showMovie, \.showSettings, \.showHelp, \.showBenchmark,
    ]
    for sheet in sheets {
      let model = model()
      model[keyPath: sheet] = true
      for command in ExplorerCommand.allCases {
        #expect(!model.canPerform(command), "\(command) acts behind \(sheet)")
      }
    }
  }

  @Test func aRepeatedShortcutLeavesItsSheetOpen() {
    // Key repeat on an iPad keyboard can deliver a shortcut twice.
    let model = model()
    for command in [ExplorerCommand.places, .help, .benchmark] {
      model.perform(command)
      model.perform(command)
    }
    #expect(model.showPlaces && model.showHelp && model.showBenchmark)
  }

  // MARK: Travel

  @Test func travelArrivesAndRecordsOnlyTheOrigin() throws {
    let model = model()
    model.travel(to: seahorse)
    let seconds = try #require(model.travelling?.seconds)
    model.advanceMotion(now: 10)
    model.advanceMotion(now: 10 + seconds / 2)
    #expect(model.travelling != nil)
    #expect(!model.canGoBack, "History was recorded mid-flight")
    model.advanceMotion(now: 10 + seconds + 0.01)
    #expect(model.travelling == nil)
    #expect(abs(model.viewport.logScale - (try seahorse.viewport()).logScale) < 1e-9)
    #expect(model.colouring.palette == seahorse.palette)
    model.perform(.back)
    #expect(abs(model.viewport.logScale) < 1e-9, "Back did not return to the origin")
    #expect(!model.canGoBack)
  }

  @Test func aGestureStopsTravelWhereItIs() throws {
    let model = model()
    model.travel(to: seahorse)
    let seconds = try #require(model.travelling?.seconds)
    model.advanceMotion(now: 10)
    model.advanceMotion(now: 10 + seconds / 2)
    let midway = model.viewport
    model.stopMotion()  // What every gesture does first.
    model.advanceMotion(now: 10 + seconds * 2)
    #expect(model.travelling == nil)
    #expect(model.viewport == midway)
    #expect(!model.canGoBack, "A stopped travel recorded history")
  }

  @Test func reduceMotionCutsStraightThere() throws {
    let model = model()
    model.reduceMotion = true
    model.travel(to: seahorse)
    #expect(model.travelling == nil)
    #expect(abs(model.viewport.logScale - (try seahorse.viewport()).logScale) < 1e-9)
    #expect(model.canGoBack)
  }

  @Test func withNoRouteItIsACut() {
    let model = model()
    model.travel(to: model.location)
    #expect(model.travelling == nil)
  }

  // MARK: Last location

  @Test func onlyAWindowRemembersWhereItWas() {
    let model = model()
    model.perform(.zoomIn)
    #expect(defaults.string(forKey: ExplorerModel.lastLocationKey) == nil)
    model.restoreLastLocation()  // What the window does; nothing saved yet.
    model.perform(.zoomIn)
    #expect(defaults.string(forKey: ExplorerModel.lastLocationKey) != nil)
  }

  @Test func aSavedPlaceIsRestoredAndGarbageIsIgnored() throws {
    defaults.set(seahorse.url.absoluteString, forKey: ExplorerModel.lastLocationKey)
    let restored = model()
    restored.restoreLastLocation()
    #expect(abs(restored.viewport.logScale - (try seahorse.viewport()).logScale) < 1e-9)
    #expect(!restored.canGoBack, "Restoring is not a move to go back from")

    defaults.set("not a link", forKey: ExplorerModel.lastLocationKey)
    let fresh = model()
    fresh.restoreLastLocation()
    #expect(fresh.viewport == Viewport())
  }
}
