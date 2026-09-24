// ExplorerModel as the UI drives it: history, menus behind a sheet, travel to
// a place, remembering where the window was, and bookmarks.  Runs in the app's
// test host, with in-memory defaults so it never touches real preferences.

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

  // MARK: Places

  @Test func placesMarksTheViewYouAreAt() {
    let model = model()
    model.apply(seahorse, record: false)
    #expect(model.isShowing(seahorse))
    // Palette and detail are not where you are.
    var recoloured = seahorse
    recoloured.palette = .fire
    recoloured.iterations = 99
    #expect(model.isShowing(recoloured))
    #expect(!model.isShowing(Location.gallery[0]))
    model.perform(.zoomIn)
    #expect(!model.isShowing(seahorse), "A zoom away still counted as the place")
  }

  @Test func bookmarksMoveOneStepAndStopAtTheEnds() {
    let store = LocationStore(defaults: defaults)
    let names = ["a", "b", "c"]
    // `add` puts each new bookmark first.
    for name in names.reversed() {
      store.add(Location(name: name, real: "0", imag: "0", scale: "1"))
    }
    #expect(store.bookmarks.map(\.name) == ["a", "b", "c"])
    store.move(store.bookmarks[0], by: -1)
    #expect(store.bookmarks.map(\.name) == ["a", "b", "c"])
    store.move(store.bookmarks[0], by: 1)
    #expect(store.bookmarks.map(\.name) == ["b", "a", "c"])
    store.move(store.bookmarks[0], to: store.bookmarks[2])
    #expect(store.bookmarks.map(\.name) == ["a", "c", "b"])
    #expect(LocationStore(defaults: defaults).bookmarks.map(\.name) == ["a", "c", "b"])
  }

  // MARK: Bookmark acknowledgement

  @Test func aSecondBookmarkFindsTheFirstInsteadOfCopyingIt() throws {
    let model = model()
    model.apply(seahorse, record: false)
    #expect(!model.isBookmarkedHere)
    model.bookmarkCurrentView()
    let first = try #require(model.bookmarkNotice)
    #expect(first.isNew)
    #expect(model.isBookmarkedHere)
    model.bookmarkCurrentView()
    let second = try #require(model.bookmarkNotice)
    #expect(!second.isNew)
    #expect(second.place.id == first.place.id)
    #expect(model.bookmarks.bookmarks.count == 1)
  }

  @Test func undoTakesTheBookmarkAndItsNoticeAway() throws {
    let model = model()
    model.bookmarkCurrentView()
    let notice = try #require(model.bookmarkNotice)
    model.undoBookmark(notice.place)
    #expect(model.bookmarks.bookmarks.isEmpty)
    #expect(model.bookmarkNotice == nil)
    #expect(!model.isBookmarkedHere)
  }

  @Test func deletingInPlacesClearsTheFilledBookmark() {
    let model = model()
    model.bookmarkCurrentView()
    #expect(model.isBookmarkedHere)
    model.bookmarks.remove(model.bookmarks.bookmarks[0])
    #expect(!model.isBookmarkedHere)
  }

  @Test func behindASheetThereIsNoNotice() {
    let model = model()
    model.showPlaces = true
    model.bookmarkCurrentView()
    #expect(model.bookmarks.bookmarks.count == 1)
    #expect(model.bookmarkNotice == nil)
  }
}
