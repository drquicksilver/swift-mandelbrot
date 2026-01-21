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
                    let t = Double(iteration) / Double(maxIterations)
                    let r = UInt8(9.0 * (1.0 - t) * t * t * t * 255.0)
                    let g = UInt8(15.0 * (1.0 - t) * (1.0 - t) * t * t * 255.0)
                    let b = UInt8(8.5 * (1.0 - t) * (1.0 - t) * (1.0 - t) * t * 255.0)
                    pixels[offset] = r
                    pixels[offset + 1] = g
                    pixels[offset + 2] = b
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
}
