//
//  MandelbrotColorizer.swift
//  Mandelbrot
//
//  Created by Jules Bean on 20/01/2026.
//

import CoreGraphics
import Foundation

struct MandelbrotColorizer {
  static func image(from iterations: MandelbrotIterations) -> CGImage? {
    let width = iterations.width
    let height = iterations.height
    let maxIterations = iterations.maxIterations
    let baseMax = 200
    var pixels = [UInt8](repeating: 0, count: width * height * 4)

    for y in 0..<height {
      for x in 0..<width {
        let iteration = iterations.value(atX: x, y: y)
        let offset = (y * width + x) * 4

        if iteration >= maxIterations {
          pixels[offset] = 0
          pixels[offset + 1] = 0
          pixels[offset + 2] = 0
          pixels[offset + 3] = 255
        } else {
          let t: Double
          var hueShift: Double = 0.0
          if iteration < baseMax {
            t = Double(iteration) / Double(baseMax)
          } else {
            let ratio = Double(iteration) / Double(baseMax)
            let log2Value = log2(ratio)
            let segment = Int(floor(log2Value))
            t = log2Value - floor(log2Value)
            hueShift = Double(segment + 1) * (60.0 / 360.0)
          }

          var r = 9.0 * (1.0 - t) * t * t * t
          var g = 15.0 * (1.0 - t) * (1.0 - t) * t * t
          var b = 8.5 * (1.0 - t) * (1.0 - t) * (1.0 - t) * t

          if hueShift != 0.0 {
            let hsv = rgbToHsv(r: r, g: g, b: b)
            let hue = (hsv.h + hueShift).truncatingRemainder(dividingBy: 1.0)
            let rgb = hsvToRgb(h: hue, s: hsv.s, v: hsv.v)
            r = rgb.r
            g = rgb.g
            b = rgb.b
          }

          pixels[offset] = UInt8(max(0.0, min(1.0, r)) * 255.0)
          pixels[offset + 1] = UInt8(max(0.0, min(1.0, g)) * 255.0)
          pixels[offset + 2] = UInt8(max(0.0, min(1.0, b)) * 255.0)
          pixels[offset + 3] = 255
        }
      }
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = width * 4
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    return pixels.withUnsafeBytes { buffer in
      guard let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
      return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    }
  }

  private static func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double)
  {
    let maxValue = max(r, g, b)
    let minValue = min(r, g, b)
    let delta = maxValue - minValue
    var hue: Double = 0.0

    if delta != 0.0 {
      if maxValue == r {
        hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6.0)
      } else if maxValue == g {
        hue = ((b - r) / delta) + 2.0
      } else {
        hue = ((r - g) / delta) + 4.0
      }
      hue /= 6.0
      if hue < 0.0 {
        hue += 1.0
      }
    }

    let saturation = maxValue == 0.0 ? 0.0 : delta / maxValue
    return (hue, saturation, maxValue)
  }

  private static func hsvToRgb(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double)
  {
    if s == 0.0 {
      return (v, v, v)
    }

    let scaled = h * 6.0
    let sector = Int(floor(scaled)) % 6
    let fraction = scaled - floor(scaled)

    let p = v * (1.0 - s)
    let q = v * (1.0 - s * fraction)
    let t = v * (1.0 - s * (1.0 - fraction))

    switch sector {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
  }
}
