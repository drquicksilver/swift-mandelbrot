//
//  RenderWorker.swift
//  Mandelbrot
//
//  Created by Jules Bean on 23/01/2026.
//

import CoreGraphics

actor RenderWorker {
    static let shared = RenderWorker()

    func renderImage(
        variant: String,
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int
    ) -> CGImage? {
        guard let iterations = renderIterations(
            variant: variant,
            width: width,
            height: height,
            center: center,
            scale: scale,
            blockSize: blockSize
        ) else {
            return nil
        }
        return MandelbrotColorizer.image(from: iterations)
    }

    private func renderIterations(
        variant: String,
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int
    ) -> MandelbrotIterations? {
        switch variant {
        case "baseline":
            return MandelbrotRenderer.iterations(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "scalar-tight":
            return MandelbrotRenderer.iterationsScalarTightened(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "coord-precompute":
            return MandelbrotRenderer.iterationsCoordPrecompute(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "unsafe-buffer":
            return MandelbrotRenderer.iterationsUnsafeBuffer(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "float-math":
            return MandelbrotRenderer.iterationsFloatMath(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "parallel":
            return MandelbrotRenderer.iterationsParallel(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "simd4-float":
            return MandelbrotRenderer.iterationsSIMD4Float(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize
            )
        case "metal":
            return MandelbrotMetalRenderer.iterations(
                width: width,
                height: height,
                center: center,
                scale: scale
            )
        default:
            return nil
        }
    }
}
