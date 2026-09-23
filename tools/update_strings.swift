// Keeps Mandelbrot/Localizable.xcstrings in step with the code, the way Xcode does.
//
// Xcode updates a string catalogue when it builds in the IDE; `xcodebuild`
// extracts the strings but never writes them back.  This does that step from
// the command line, from the `.stringsdata` the Mac and iOS builds leave, and it
// writes exactly what Xcode writes -- the same keys, the same order
// (`localizedStandardCompare`), the same layout -- so the two never fight over
// the file.  A key the code has dropped goes if it was never translated, and is
// marked stale for a person to decide about if it was.  Existing entries,
// including anything Xcode added to them, are kept as they are.  The one
// thing it does not reproduce is the positional form ("%1$@ · %2$@") Xcode
// gives a few new keys; Xcode adds that the next time it builds, and this
// keeps it from then on.
//
//     swift tools/update_strings.swift [--check] BUILD_DIR [BUILD_DIR ...]
//
// `--check` writes nothing and exits 1 if the catalogue is out of date.

import Foundation

let catalogue = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("Mandelbrot/Localizable.xcstrings")

var arguments = Array(CommandLine.arguments.dropFirst())
let checking = arguments.first == "--check"
if checking { arguments.removeFirst() }
guard !arguments.isEmpty else {
  FileHandle.standardError.write(
    Data("usage: update_strings.swift [--check] BUILD_DIR [BUILD_DIR ...]\n".utf8))
  exit(2)
}

// Every key the compiler extracted into the default table, with its comment.
var found: [String: String] = [:]
for directory in arguments {
  let root = URL(fileURLWithPath: directory)
  let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
  while let file = files?.nextObject() as? URL {
    guard file.pathExtension == "stringsdata",
      let data = try? Data(contentsOf: file),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tables = json["tables"] as? [String: Any],
      let entries = tables["Localizable"] as? [[String: Any]]
    else { continue }
    for entry in entries {
      guard let key = entry["key"] as? String else { continue }
      let comment = entry["comment"] as? String ?? ""
      if found[key]?.isEmpty ?? true { found[key] = comment }
    }
  }
}
guard !found.isEmpty else {
  FileHandle.standardError.write(
    Data("No extracted strings: build the app first (make build ios).\n".utf8))
  exit(2)
}

let existingText = (try? String(contentsOf: catalogue, encoding: .utf8)) ?? ""
var document =
  (try? JSONSerialization.jsonObject(with: Data(existingText.utf8)) as? [String: Any])
  ?? ["sourceLanguage": "en", "version": "1.0"]
var strings = document["strings"] as? [String: Any] ?? [:]
for (key, comment) in found {
  var entry = strings[key] as? [String: Any] ?? [:]
  entry["extractionState"] = nil
  if !comment.isEmpty { entry["comment"] = comment }
  strings[key] = entry
}
for key in strings.keys where found[key] == nil {
  guard var entry = strings[key] as? [String: Any], entry["localizations"] != nil else {
    strings[key] = nil
    continue
  }
  entry["extractionState"] = "stale"
  strings[key] = entry
}
document["strings"] = strings

/// Xcode's layout: two-space indents, " : " between key and value, an empty
/// object as an open line, keys in `localizedStandardCompare` order, and no
/// newline at the end.
func encode(_ value: Any, depth: Int) -> String {
  let indent = String(repeating: "  ", count: depth)
  switch value {
  case let object as [String: Any]:
    if object.isEmpty { return "{\n\n\(indent)}" }
    let keys = object.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let members = keys.map { "\(indent)  \(quote($0)) : \(encode(object[$0]!, depth: depth + 1))" }
    return "{\n" + members.joined(separator: ",\n") + "\n\(indent)}"
  case let array as [Any]:
    if array.isEmpty { return "[\n\n\(indent)]" }
    let members = array.map { "\(indent)  \(encode($0, depth: depth + 1))" }
    return "[\n" + members.joined(separator: ",\n") + "\n\(indent)]"
  case let string as String:
    return quote(string)
  case let number as NSNumber:
    return CFGetTypeID(number) == CFBooleanGetTypeID()
      ? (number.boolValue ? "true" : "false") : number.stringValue
  default:
    return "null"
  }
}

func quote(_ string: String) -> String {
  let data = try! JSONSerialization.data(
    withJSONObject: string, options: [.fragmentsAllowed, .withoutEscapingSlashes])
  return String(decoding: data, as: UTF8.self)
}

let text = encode(document, depth: 0)
let stale = strings.values.filter {
  ($0 as? [String: Any])?["extractionState"] as? String == "stale"
}
.count
if text == existingText {
  print("\(found.count) strings, \(stale) stale: up to date")
} else if checking {
  print("\(catalogue.lastPathComponent) is out of date: run make strings")
  exit(1)
} else {
  try! text.write(to: catalogue, atomically: true, encoding: .utf8)
  print("\(found.count) strings, \(stale) stale, written")
}
