//
//  MandelbrotRenderer.swift
//  Mandelbrot
//
//  Created by Jules Bean on 20/01/2026.
//

import CoreGraphics
import Dispatch
import simd

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

    static func iterationsScalarTightened(
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

    static func iterationsCoordPrecompute(
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
        let realStep = realSpan / widthDenominator
        let imagStep = imagSpan / heightDenominator
        let halfBlock = blockSize / 2

        for y in stride(from: 0, to: height, by: blockSize) {
            let yEnd = min(height, y + blockSize)
            let ySample = min(height - 1, y + halfBlock)
            let imag = imagMax - Double(ySample) * imagStep

            for x in stride(from: 0, to: width, by: blockSize) {
                let xEnd = min(width, x + blockSize)
                let xSample = min(width - 1, x + halfBlock)
                let real = realMin + Double(xSample) * realStep
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

    static func iterationsUnsafeBuffer(
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

        values.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
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
                        let rowStart = yy * width
                        let rowBase = base.advanced(by: rowStart)
                        for xx in x..<xEnd {
                            let offset = rowStart + xx
                            if offset < buffer.count {
                                rowBase[xx] = iteration
                            }
                        }
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

    static func iterationsFloatMath(
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int,
        configuration: MandelbrotConfiguration = MandelbrotConfiguration()
    ) -> MandelbrotIterations {
        let maxIterations = configuration.maxIterations
        let baseSpan = Float(configuration.baseSpan)
        let realSpan = baseSpan / Float(scale)
        let imagSpan = realSpan * Float(height) / Float(width)
        let realMin = Float(center.x) - realSpan / 2.0
        let realMax = Float(center.x) + realSpan / 2.0
        let imagMin = Float(center.y) - imagSpan / 2.0
        let imagMax = Float(center.y) + imagSpan / 2.0

        var values = [Int](repeating: 0, count: width * height)
        let heightDenominator = Float(max(1, height - 1))
        let widthDenominator = Float(max(1, width - 1))

        for y in stride(from: 0, to: height, by: blockSize) {
            let yEnd = min(height, y + blockSize)
            let ySample = min(height - 1, y + blockSize / 2)
            let imag = imagMax - (Float(ySample) / heightDenominator) * imagSpan

            for x in stride(from: 0, to: width, by: blockSize) {
                let xEnd = min(width, x + blockSize)
                let xSample = min(width - 1, x + blockSize / 2)
                let real = realMin + (Float(xSample) / widthDenominator) * realSpan
                var zr: Float = 0
                var zi: Float = 0
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

    static func iterationsParallel(
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

        let count = width * height
        let heightDenominator = Double(max(1, height - 1))
        let widthDenominator = Double(max(1, width - 1))
        let blockCount = Int(ceil(Double(height) / Double(blockSize)))

        let buffer = UnsafeMutablePointer<Int>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
        let bufferCount = count

        DispatchQueue.concurrentPerform(iterations: blockCount) { blockIndex in
            let y = blockIndex * blockSize
            if y >= height { return }
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
                    let rowStart = yy * width
                    for xx in x..<xEnd {
                        let offset = rowStart + xx
                        if offset < bufferCount {
                            buffer[offset] = iteration
                        }
                    }
                }
            }
        }

        let values = Array(UnsafeBufferPointer(start: buffer, count: bufferCount))
        buffer.deinitialize(count: bufferCount)
        buffer.deallocate()

        return MandelbrotIterations(
            width: width,
            height: height,
            maxIterations: maxIterations,
            values: values
        )
    }

    static func iterationsSIMD4Float(
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int,
        configuration: MandelbrotConfiguration = MandelbrotConfiguration()
    ) -> MandelbrotIterations {
        if blockSize != 1 {
            return iterationsFloatMath(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        }

        let maxIterations = configuration.maxIterations
        let baseSpan = Float(configuration.baseSpan)
        let realSpan = baseSpan / Float(scale)
        let imagSpan = realSpan * Float(height) / Float(width)
        let realMin = Float(center.x) - realSpan / 2.0
        let realMax = Float(center.x) + realSpan / 2.0
        let imagMin = Float(center.y) - imagSpan / 2.0
        let imagMax = Float(center.y) + imagSpan / 2.0

        var values = [Int](repeating: 0, count: width * height)
        let heightDenominator = Float(max(1, height - 1))
        let widthDenominator = Float(max(1, width - 1))
        let realStep = realSpan / widthDenominator
        let imagStep = imagSpan / heightDenominator

        let four = SIMD4<Float>(repeating: 4.0)

        for y in 0..<height {
            let imag = imagMax - Float(y) * imagStep
            let rowOffset = y * width

            var x = 0
            while x + 3 < width {
                let baseX = Float(x)
                let realVec = realMin + (SIMD4<Float>(baseX, baseX + 1, baseX + 2, baseX + 3) * realStep)
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
                let real = realMin + Float(x) * realStep
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
            width: width,
            height: height,
            maxIterations: maxIterations,
            values: values
        )
    }
}
