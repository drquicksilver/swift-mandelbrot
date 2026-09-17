import Combine
import Foundation

/// Bookmarks, saved as JSON in user defaults.  The starter gallery is separate
/// and never stored, so it can grow with the app.
@MainActor final class LocationStore: ObservableObject {
  @Published private(set) var bookmarks: [Location] = []
  private let defaults: UserDefaults
  private let key: String
  init(defaults: UserDefaults = .standard, key: String = "Bookmarks") {
    self.defaults = defaults
    self.key = key
    if let data = defaults.data(forKey: key),
      let saved = try? JSONDecoder().decode([Location].self, from: data)
    {
      bookmarks = saved
    }
  }
  func add(_ location: Location) {
    bookmarks.removeAll { $0.id == location.id }
    bookmarks.insert(location, at: 0)
    // A cap keeps the defaults small; the oldest bookmark drops out.
    if bookmarks.count > 200 { bookmarks.removeLast(bookmarks.count - 200) }
    save()
  }
  func remove(_ location: Location) {
    bookmarks.removeAll { $0.id == location.id }
    save()
  }
  func rename(_ location: Location, to name: String) {
    guard let index = bookmarks.firstIndex(where: { $0.id == location.id }) else { return }
    bookmarks[index].name = name
    save()
  }
  private func save() {
    guard let data = try? JSONEncoder().encode(bookmarks) else { return }
    defaults.set(data, forKey: key)
  }
}
