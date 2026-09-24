import CoreGraphics
import Dispatch
import simd

struct MandelbrotConfiguration {
  var maxIterations: Int = 200
  var baseSpan: Double = 3.0
}

/// Plain escape counts, row-major from the top: the lab renderers' output,
/// which the CLI colours or writes out as `--counts`.
struct MandelbrotIterations {
  let width: Int
  let height: Int
  let maxIterations: Int
  private var values: [Int]

  init(width: Int, height: Int, maxIterations: Int, values: [Int]) {
    self.width = width
    self.height = height
    self.maxIterations = maxIterations
    self.values = values
  }

  func value(atX x: Int, y: Int) -> Int {
    values[y * width + x]
  }
}

/// The view as the lab renderers see it: pixel (x, y) samples the plane at
/// its centre, `left + (x + 0.5) * step`, as the tiles and every GPU path do.
/// Pixels are square, so one step serves both axes.
private struct PixelGrid<Scalar: BinaryFloatingPoint> {
  let left: Scalar
  let top: Scalar
  let realSpan: Scalar
  let imagSpan: Scalar
  let step: Scalar
  init(width: Int, height: Int, center: CGPoint, scale: Double, baseSpan: Double) {
    let span = baseSpan / scale
    realSpan = Scalar(span)
    imagSpan = Scalar(span * Double(height) / Double(width))
    left = Scalar(center.x - span / 2)
    top = Scalar(center.y + span * Double(height) / Double(width) / 2)
    step = Scalar(span / Double(width))
  }
}

/// The CPU renderers from the first performance experiments, kept as a
/// laboratory: each variant changes one thing about the same escape-time
/// loop, so `--benchmark` can show what that one thing is worth (see
/// Performance-history.md, Phase 1).  The Double variants reproduce the
/// golden fixtures exactly; the Float ones show what single precision loses.
/// None of them draws the viewer, which renders tiles on the GPU.
enum MandelbrotRenderer {
  /// The reference: Double arithmetic, the coordinate worked out per pixel
  /// from its fraction of the span, and the textbook loop.
  static func iterations(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Double>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    for y in 0..<height {
      let imag = grid.top - (Double(y) + 0.5) / Double(height) * grid.imagSpan
      for x in 0..<width {
        let real = grid.left + (Double(x) + 0.5) / Double(width) * grid.realSpan
        var zr = 0.0
        var zi = 0.0
        var iteration = 0
        while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
          let temp = zr * zr - zi * zi + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          iteration += 1
        }
        values[y * width + x] = iteration
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// The reference with the squares kept between iterations and the escape
  /// test moved after the update, so each iteration multiplies three times.
  static func iterationsScalarTightened(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Double>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    for y in 0..<height {
      let imag = grid.top - (Double(y) + 0.5) / Double(height) * grid.imagSpan
      for x in 0..<width {
        let real = grid.left + (Double(x) + 0.5) / Double(width) * grid.realSpan
        var zr = 0.0
        var zi = 0.0
        var zr2 = 0.0
        var zi2 = 0.0
        var iteration = maxIterations
        for i in 0..<maxIterations {
          let temp = zr2 - zi2 + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          zr2 = zr * zr
          zi2 = zi * zi
          if zr2 + zi2 > 4.0 {
            iteration = i + 1
            break
          }
        }
        values[y * width + x] = iteration
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// The reference with the per-pixel division replaced by a precomputed step.
  static func iterationsCoordPrecompute(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Double>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    for y in 0..<height {
      let imag = grid.top - (Double(y) + 0.5) * grid.step
      for x in 0..<width {
        let real = grid.left + (Double(x) + 0.5) * grid.step
        var zr = 0.0
        var zi = 0.0
        var iteration = 0
        while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
          let temp = zr * zr - zi * zi + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          iteration += 1
        }
        values[y * width + x] = iteration
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// The reference writing through an unsafe pointer, without bounds checks.
  static func iterationsUnsafeBuffer(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Double>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    values.withUnsafeMutableBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      for y in 0..<height {
        let imag = grid.top - (Double(y) + 0.5) / Double(height) * grid.imagSpan
        let row = base.advanced(by: y * width)
        for x in 0..<width {
          let real = grid.left + (Double(x) + 0.5) / Double(width) * grid.realSpan
          var zr = 0.0
          var zi = 0.0
          var iteration = 0
          while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
            let temp = zr * zr - zi * zi + real
            zi = 2.0 * zr * zi + imag
            zr = temp
            iteration += 1
          }
          row[x] = iteration
        }
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// The reference in Float: faster, and visibly wrong well before 1e7.
  static func iterationsFloatMath(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Float>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    for y in 0..<height {
      let imag = grid.top - (Float(y) + 0.5) / Float(height) * grid.imagSpan
      for x in 0..<width {
        let real = grid.left + (Float(x) + 0.5) / Float(width) * grid.realSpan
        var zr: Float = 0
        var zi: Float = 0
        var iteration = 0
        while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
          let temp = zr * zr - zi * zi + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          iteration += 1
        }
        values[y * width + x] = iteration
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// The reference with its rows spread across every core.
  static func iterationsParallel(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Double>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    let count = width * height
    let buffer = UnsafeMutablePointer<Int>.allocate(capacity: count)
    buffer.initialize(repeating: 0, count: count)
    DispatchQueue.concurrentPerform(iterations: height) { y in
      let imag = grid.top - (Double(y) + 0.5) / Double(height) * grid.imagSpan
      let row = buffer.advanced(by: y * width)
      for x in 0..<width {
        let real = grid.left + (Double(x) + 0.5) / Double(width) * grid.realSpan
        var zr = 0.0
        var zi = 0.0
        var iteration = 0
        while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
          let temp = zr * zr - zi * zi + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          iteration += 1
        }
        row[x] = iteration
      }
    }
    let values = Array(UnsafeBufferPointer(start: buffer, count: count))
    buffer.deinitialize(count: count)
    buffer.deallocate()
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }

  /// Four Float pixels at a time in SIMD lanes, which run until the last of
  /// the four escapes; a row's leftover pixels take the scalar loop.
  static func iterationsSIMD4Float(
    width: Int, height: Int, center: CGPoint, scale: Double,
    configuration: MandelbrotConfiguration = MandelbrotConfiguration()
  ) -> MandelbrotIterations {
    let maxIterations = configuration.maxIterations
    let grid = PixelGrid<Float>(
      width: width, height: height, center: center, scale: scale,
      baseSpan: configuration.baseSpan)
    var values = [Int](repeating: 0, count: width * height)
    let four = SIMD4<Float>(repeating: 4.0)
    for y in 0..<height {
      let imag = grid.top - (Float(y) + 0.5) * grid.step
      let rowOffset = y * width
      var x = 0
      while x + 3 < width {
        let baseX = Float(x) + 0.5
        let realVec =
          grid.left + (SIMD4<Float>(baseX, baseX + 1, baseX + 2, baseX + 3) * grid.step)
        var zr = SIMD4<Float>(repeating: 0)
        var zi = SIMD4<Float>(repeating: 0)
        var counts = SIMD4<Int32>(repeating: 0)
        for _ in 0..<maxIterations {
          let zr2 = zr * zr
          let zi2 = zi * zi
          let mask = (zr2 + zi2) .<= four
          if !mask[0] && !mask[1] && !mask[2] && !mask[3] {
            break
          }
          if mask[0] { counts[0] &+= 1 }
          if mask[1] { counts[1] &+= 1 }
          if mask[2] { counts[2] &+= 1 }
          if mask[3] { counts[3] &+= 1 }
          let temp = zr2 - zi2 + realVec
          zi = (zr * zi * 2.0) + SIMD4<Float>(repeating: imag)
          zr = temp
        }
        values[rowOffset + x] = Int(counts[0])
        values[rowOffset + x + 1] = Int(counts[1])
        values[rowOffset + x + 2] = Int(counts[2])
        values[rowOffset + x + 3] = Int(counts[3])
        x += 4
      }
      while x < width {
        let real = grid.left + (Float(x) + 0.5) * grid.step
        var zr: Float = 0
        var zi: Float = 0
        var iteration = 0
        while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
          let temp = zr * zr - zi * zi + real
          zi = 2.0 * zr * zi + imag
          zr = temp
          iteration += 1
        }
        values[rowOffset + x] = iteration
        x += 1
      }
    }
    return MandelbrotIterations(
      width: width, height: height, maxIterations: maxIterations, values: values)
  }
}
