//
//  MandelbrotRenderer.swift
//  Mandelbrot
//
//  Created by Jules Bean on 20/01/2026.
//

import CoreGraphics

struct MandelbrotConfiguration {
    var maxIterations: Int = 200
    var baseSpan: Double = 3.0
}

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

struct MandelbrotRenderer {
    static func iterations(
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int,
        configuration: MandelbrotConfiguration = MandelbrotConfiguration()
    ) -> MandelbrotIterations {
        let maxIterations = configuration.maxIterations
        let baseSpan = configuration.baseSpan
        let realSpan = baseSpan / scale
        let imagSpan = realSpan * Double(height) / Double(width)
        let realMin = center.x - realSpan / 2.0
        let realMax = center.x + realSpan / 2.0
        let imagMin = center.y - imagSpan / 2.0
        let imagMax = center.y + imagSpan / 2.0

        var values = [Int](repeating: 0, count: width * height)

        let heightDenominator = Double(max(1, height - 1))
        let widthDenominator = Double(max(1, width - 1))

        for y in stride(from: 0, to: height, by: blockSize) {
            let yEnd = min(height, y + blockSize)
            let ySample = min(height - 1, y + blockSize / 2)
            let imag = imagMax - (Double(ySample) / heightDenominator) * imagSpan

            for x in stride(from: 0, to: width, by: blockSize) {
                let xEnd = min(width, x + blockSize)
                let xSample = min(width - 1, x + blockSize / 2)
                let real = realMin + (Double(xSample) / widthDenominator) * realSpan
                var zr = 0.0
                var zi = 0.0
                var iteration = 0

                while zr * zr + zi * zi <= 4.0 && iteration < maxIterations {
                    let temp = zr * zr - zi * zi + real
                    zi = 2.0 * zr * zi + imag
                    zr = temp
                    iteration += 1
                }

                for yy in y..<yEnd {
                    for xx in x..<xEnd {
                        values[yy * width + xx] = iteration
                    }
                }
            }
        }

        return MandelbrotIterations(
            width: width,
            height: height,
            maxIterations: maxIterations,
            values: values
        )
    }
}
