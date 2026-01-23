//
//  MandelbrotMetalRenderer.swift
//  Mandelbrot
//
//  Created by Jules Bean on 23/01/2026.
//

import CoreGraphics
import Metal

struct MandelbrotMetalRenderer {
    static func iterations(
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        configuration: MandelbrotConfiguration = MandelbrotConfiguration()
    ) -> MandelbrotIterations? {
        MandelbrotMetalContext.shared.renderIterations(
            width: width,
            height: height,
            center: center,
            scale: scale,
            configuration: configuration
        )
    }
}

final class MandelbrotMetalContext {
    static let shared = MandelbrotMetalContext()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let device {
            let library = device.makeDefaultLibrary()
            let function = library?.makeFunction(name: "mandelbrotIterations")
            if let function {
                self.pipelineState = try? device.makeComputePipelineState(function: function)
            } else {
                self.pipelineState = nil
            }
        } else {
            self.pipelineState = nil
        }
    }

    func renderIterations(
        width: Int,
        height: Int,
        center: CGPoint,
        scale: Double,
        configuration: MandelbrotConfiguration
    ) -> MandelbrotIterations? {
        guard
            let device,
            let commandQueue,
            let pipelineState
        else {
            return nil
        }

        let count = width * height
        guard count > 0 else { return nil }

        let bufferLength = count * MemoryLayout<UInt16>.stride
        guard let iterationsBuffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else {
            return nil
        }

        var params = MandelbrotParams(
            width: UInt32(width),
            height: UInt32(height),
            centerX: Float(center.x),
            centerY: Float(center.y),
            scale: Float(scale),
            maxIterations: UInt32(configuration.maxIterations),
            baseSpan: Float(configuration.baseSpan)
        )

        guard let paramsBuffer = device.makeBuffer(
            bytes: &params,
            length: MemoryLayout<MandelbrotParams>.stride,
            options: .storageModeShared
        ) else {
            return nil
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(iterationsBuffer, offset: 0, index: 0)
        encoder.setBuffer(paramsBuffer, offset: 0, index: 1)

        let threadWidth = pipelineState.threadExecutionWidth
        let threadHeight = max(1, pipelineState.maxTotalThreadsPerThreadgroup / threadWidth)
        let threadsPerThreadgroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let raw = iterationsBuffer.contents().bindMemory(to: UInt16.self, capacity: count)
        var values = [Int](repeating: 0, count: count)
        for index in 0..<count {
            values[index] = Int(raw[index])
        }

        return MandelbrotIterations(
            width: width,
            height: height,
            maxIterations: configuration.maxIterations,
            values: values
        )
    }
}

struct MandelbrotParams {
    var width: UInt32
    var height: UInt32
    var centerX: Float
    var centerY: Float
    var scale: Float
    var maxIterations: UInt32
    var baseSpan: Float
    var padding: Float = 0
}
