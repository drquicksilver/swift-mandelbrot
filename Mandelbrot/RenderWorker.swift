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
        blockSize: Int,
        configuration: MandelbrotConfiguration = MandelbrotConfiguration()
    ) -> CGImage? {
        guard let iterations = renderIterations(
            variant: variant,
            width: width,
            height: height,
            center: center,
            scale: scale,
            blockSize: blockSize,
            configuration: configuration
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
        blockSize: Int,
        configuration: MandelbrotConfiguration
    ) -> MandelbrotIterations? {
        switch variant {
        case "baseline":
            return MandelbrotRenderer.iterations(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "scalar-tight":
            return MandelbrotRenderer.iterationsScalarTightened(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "coord-precompute":
            return MandelbrotRenderer.iterationsCoordPrecompute(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "unsafe-buffer":
            return MandelbrotRenderer.iterationsUnsafeBuffer(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "float-math":
            return MandelbrotRenderer.iterationsFloatMath(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "parallel":
            return MandelbrotRenderer.iterationsParallel(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "simd4-float":
            return MandelbrotRenderer.iterationsSIMD4Float(
                width: width,
                height: height,
                center: center,
                scale: scale,
                blockSize: blockSize,
                configuration: configuration
            )
        case "metal":
            return MandelbrotMetalRenderer.iterations(
                width: width,
                height: height,
                center: center,
                scale: scale,
                configuration: configuration
            )
        default:
            return nil
        }
    }
}
