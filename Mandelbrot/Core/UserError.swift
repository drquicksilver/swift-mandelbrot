import Foundation

/// An error whose text is written for people: a sentence to show as it is.
/// Anything else thrown is written for the code, and whatever shows it must
/// say something of its own instead.
struct UserError: Error, CustomStringConvertible, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var description: String { message }
  var errorDescription: String? { message }
}
