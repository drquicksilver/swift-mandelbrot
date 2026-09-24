import Combine
import Foundation

#if os(macOS)
  import AppKit

  /// Where movies are written.  Renders used to land in `temporaryDirectory`,
  /// so anything made before this was one purge from gone.  On macOS the user
  /// chooses a folder once; until they do it is `~/Movies`.  The choice is kept
  /// as a security-scoped bookmark, which is what survives both a relaunch and
  /// the sandbox the Mac App Store will want.
  @MainActor final class MovieLibrary: ObservableObject {
    static let shared = MovieLibrary()
    static let bookmarkKey = "MovieFolderBookmark"
    @Published private(set) var folder: URL
    /// A chosen folder is entered once and stays entered: the app writes to it
    /// for as long as it runs, and there is nothing to balance on the way out.
    private var scoped: URL?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
      folder = Self.defaultFolder
      restore()
    }
    static var defaultFolder: URL {
      FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
    }
    /// Reopens the remembered folder, if there still is one.
    private func restore() {
      guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
      var stale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
          bookmarkDataIsStale: &stale)
      else {
        defaults.removeObject(forKey: Self.bookmarkKey)
        return
      }
      _ = url.startAccessingSecurityScopedResource()
      scoped = url
      folder = url
      if stale { remember(url) }
    }
    private func remember(_ url: URL) {
      guard
        let data = try? url.bookmarkData(
          options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      else { return }
      defaults.set(data, forKey: Self.bookmarkKey)
    }
    /// Takes a folder the user picked, remembering it for next time.
    func adopt(_ url: URL) {
      scoped?.stopAccessingSecurityScopedResource()
      _ = url.startAccessingSecurityScopedResource()
      scoped = url
      folder = url
      remember(url)
    }
    func forget() {
      scoped?.stopAccessingSecurityScopedResource()
      scoped = nil
      defaults.removeObject(forKey: Self.bookmarkKey)
      folder = Self.defaultFolder
    }
    func choose() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.canCreateDirectories = true
      panel.directoryURL = folder
      panel.prompt = "Choose"
      panel.message = "Where should zoom movies be saved?"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      adopt(url)
    }
    /// The file a new render should write, in the chosen folder.
    func destination(named name: String) -> URL {
      try? FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true)
      return folder.appendingPathComponent(name)
    }
    func reveal(_ url: URL) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }
#endif

/// The name a render writes under, so a folder full of them stays sortable.
enum MovieNaming {
  static func fileName(now: Date = Date()) -> String {
    let stamp = DateFormatter()
    stamp.locale = Locale(identifier: "en_US_POSIX")
    stamp.dateFormat = "yyyy-MM-dd-HHmmss"
    return "Mandelbrot zoom \(stamp.string(from: now)).mov"
  }
}
