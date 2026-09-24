// A place as data: everything needed to show a view again, in a form that
// survives a mandelbrot:// link, a bookmark and a movie's ends.  Also the
// famous places the app ships with (`gallery`).

import CoreGraphics
import Foundation

/// A place in the set: the centre as arbitrary-precision decimal strings, the
/// scale as a decimal string, the rotation, the iteration limit (nil means
/// automatic) and the palette.  Everything a view needs, in a form that survives
/// a URL, a bookmark file and a zoom movie's keyframes.
struct Location: Codable, Equatable, Sendable, Identifiable {
  var id = UUID()
  var name = ""
  var real: String
  var imag: String
  var scale: String
  var rotationDegrees = 0.0
  var iterations: Int?
  var palette = Palette.blueGold
  var density = 64.0
  var offset = 0.0
  /// Present only on post-2.11 snapshots. Old locations remain deliberately
  /// pinned to their historic density/offset.
  var automaticColour: Bool?
  var densityAdjustment: Double?
  var offsetAdjustment: Double?
  var created = Date()

  static let scheme = "mandelbrot"
  static let host = "view"

  init(
    name: String = "", real: String, imag: String, scale: String, rotationDegrees: Double = 0,
    iterations: Int? = nil, palette: Palette = .blueGold, density: Double = 64,
    offset: Double = 0, automaticColour: Bool? = nil, densityAdjustment: Double? = nil,
    offsetAdjustment: Double? = nil, id: UUID = UUID(), created: Date = Date()
  ) {
    self.name = name
    self.real = real
    self.imag = imag
    self.scale = scale
    self.rotationDegrees = rotationDegrees
    self.iterations = iterations
    self.palette = palette
    self.density = density
    self.offset = offset
    self.automaticColour = automaticColour
    self.densityAdjustment = densityAdjustment
    self.offsetAdjustment = offsetAdjustment
    self.id = id
    self.created = created
  }
  init(
    viewport: Viewport, iterations: Int? = nil, colouring: ColourSettings = ColourSettings(),
    name: String = "", automaticColour: Bool? = nil, densityAdjustment: Double? = nil,
    offsetAdjustment: Double? = nil, id: UUID = UUID(), created: Date = Date()
  ) {
    let centre = viewport.centerDescription.components(separatedBy: ", ")
    self.init(
      name: name, real: centre.first ?? "0", imag: centre.count > 1 ? centre[1] : "0",
      scale: viewport.scaleDescription,
      rotationDegrees: viewport.angle * 180 / .pi, iterations: iterations,
      palette: colouring.palette, density: Double(colouring.density),
      offset: Double(colouring.offset), automaticColour: automaticColour,
      densityAdjustment: densityAdjustment, offsetAdjustment: offsetAdjustment,
      id: id, created: created)
  }
  func viewport() throws -> Viewport {
    var view = try Viewport(real: real, imag: imag, zoom: scale)
    guard rotationDegrees.isFinite, abs(rotationDegrees) <= 360 else {
      throw PrecisionError("Rotation outside [-360, 360]")
    }
    view.angle = Viewport.normalised(rotationDegrees * .pi / 180)
    return view
  }
  /// Depth and auto-contrast colouring both count in octaves; only a historic
  /// location, which has neither, counts linearly in iterations.
  var colouring: ColourSettings {
    ColourSettings(
      palette: palette, density: Float(density), offset: Float(offset), smooth: true,
      logarithmic: automaticColour != nil)
  }
  /// A link anyone can open: `mandelbrot://view?re=...&im=...&zoom=...`.
  var url: URL {
    var components = URLComponents()
    components.scheme = Self.scheme
    components.host = Self.host
    var items = [
      URLQueryItem(name: "re", value: real), URLQueryItem(name: "im", value: imag),
      URLQueryItem(name: "zoom", value: scale),
    ]
    if rotationDegrees != 0 {
      items.append(URLQueryItem(name: "rot", value: String(rotationDegrees)))
    }
    if let iterations { items.append(URLQueryItem(name: "iter", value: String(iterations))) }
    if palette != .blueGold { items.append(URLQueryItem(name: "palette", value: palette.rawValue)) }
    if density != 64 { items.append(URLQueryItem(name: "density", value: String(density))) }
    if offset != 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
    if let automaticColour {
      items.append(URLQueryItem(name: "colour", value: automaticColour ? "auto" : "depth"))
      if let densityAdjustment, densityAdjustment != 1 {
        items.append(URLQueryItem(name: "density-adjust", value: String(densityAdjustment)))
      }
      if let offsetAdjustment, offsetAdjustment != 0 {
        items.append(URLQueryItem(name: "offset-adjust", value: String(offsetAdjustment)))
      }
    }
    if !name.isEmpty { items.append(URLQueryItem(name: "name", value: name)) }
    components.queryItems = items
    return components.url!
  }
  /// Accepts the app's own scheme and the matching universal-link path, so a
  /// shared link keeps working if the site ever serves one.
  init(url: URL) throws {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw PrecisionError("Malformed location link")
    }
    let scheme = components.scheme?.lowercased()
    let isApp = scheme == Self.scheme && (components.host ?? Self.host).lowercased() == Self.host
    let isWeb =
      (scheme == "https" || scheme == "http") && components.path.hasSuffix("/" + Self.host)
    guard isApp || isWeb else { throw PrecisionError("Not a Mandelbrot location link") }
    let values = Dictionary(
      (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
      uniquingKeysWith: { _, last in last })
    guard let real = values["re"], let imag = values["im"], let scale = values["zoom"] else {
      throw PrecisionError("Location link needs re, im and zoom")
    }
    var iterations: Int?
    if let text = values["iter"], text.lowercased() != "auto" {
      guard let value = Int(text), value > 0, value <= IterationPolicy.maximum else {
        throw PrecisionError("Location link has an invalid iteration limit")
      }
      iterations = value
    }
    var palette = Palette.blueGold
    if let text = values["palette"] {
      guard let named = Palette(rawValue: text) else {
        throw PrecisionError("Unknown palette: \(text)")
      }
      palette = named
    }
    func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws
      -> Double
    {
      guard let text = values[key] else { return fallback }
      guard let value = Double(text), value.isFinite, range.contains(value) else {
        throw PrecisionError("Location link has an invalid \(key)")
      }
      return value
    }
    self.init(
      name: values["name"] ?? "", real: real, imag: imag, scale: scale,
      rotationDegrees: try number("rot", default: 0, range: -360...360), iterations: iterations,
      palette: palette, density: try number("density", default: 64, range: 1...100_000),
      offset: try number("offset", default: 0, range: -1000...1000),
      automaticColour: values["colour"] == "auto"
        ? true : (values["colour"] == "depth" ? false : nil),
      densityAdjustment: values["colour"] == "auto" || values["colour"] == "depth"
        ? try number("density-adjust", default: 1, range: 0.125...16) : nil,
      offsetAdjustment: values["colour"] == "auto" || values["colour"] == "depth"
        ? try number("offset-adjust", default: 0, range: -1000...1000) : nil)
    // Reject centres and scales the renderer cannot represent, at parse time.
    _ = try self.viewport()
  }

  /// Famous places, which double as onboarding for friends and family.
  static let gallery: [Location] = [
    Location(
      name: "The whole set", real: "-0.5", imag: "0", scale: "1", palette: .blueGold),
    Location(
      name: "Seahorse Valley", real: "-0.743643887037151", imag: "0.13182590420533",
      scale: "4e3", palette: .ink),
    Location(
      name: "Elephant Valley", real: "0.2821", imag: "0.01", scale: "2e3", palette: .fire),
    Location(
      name: "Triple Spiral", real: "-0.088", imag: "0.654", scale: "1.5e3", palette: .twilight),
    Location(
      name: "Scepter Valley", real: "-1.7499", imag: "0", scale: "3e4", palette: .ice),
    Location(
      name: "Mini Mandelbrot", real: "-1.768122587728", imag: "0.006252132362",
      scale: "8e4", palette: .forest),
    Location(
      name: "Feather", real: "-0.1631", imag: "-1.0320", scale: "5e3", palette: .orbit),
    Location(
      name: "The point i", real: "0", imag: "1", scale: "1e12", palette: .ink),
    Location(
      name: "Period-312 satellite",
      real:
        "-0.74364446677499950770653780732947227038",
      imag:
        "0.13182589800194177628521553600165270872",
      scale: "3e5", palette: .ink, density: 512),
  ]
}
