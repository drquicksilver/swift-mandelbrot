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

    func renderIterations(
        variant: String,
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        blockSize: Int,
        configuration: MandelbrotConfiguration
    ) -> MandelbrotIterations? {
        guard let id = RendererID(rawValue: variant) else { return nil }
        return RendererRegistry.renderer(for: id).iterations(RenderRequest(
            width: width, height: height, viewport: Viewport(center: center, scale: scale),
            blockSize: blockSize, configuration: configuration))
    }
}
