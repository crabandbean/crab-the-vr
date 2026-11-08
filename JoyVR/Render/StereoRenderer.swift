//
//  StereoRenderer.swift
//  JoyVR
//
//  Draws the side-by-side frame the PC sent as two eye images, each pre-warped
//  for the headset lens in front of it.
//

import CoreVideo
import Metal
import MetalKit
import simd

private struct QuadVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

struct QuadUniforms {
    var k = SIMD2<Float>(0.20, 0.04)
    var center = SIMD2<Float>(0.5, 0.5)
    var chroma: Float = 0
    var brightness: Float = 1
    var mode: Float = 1
    var aspect: Float = 1
    var eyeIndex: Float = 0
    var saturation: Float = 1
    var vignette: Float = 0
}

final class StereoRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?

    private weak var stream: StreamPipeline?
    private var texture: MTLTexture?

    var showTestPattern = true

    // Picture controls, set from the Tune screen.
    var distortionK1: Float = 0.20
    var distortionK2: Float = 0.04
    var chromaticAberration: Float = 0
    var brightness: Float = 1
    var saturation: Float = 1
    var vignette: Float = 0

    init?(device: MTLDevice, stream: StreamPipeline) {
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "joyvr_vertex"),
              let fragmentFunction = library.makeFunction(name: "joyvr_fragment"),
              let queue = device.makeCommandQueue() else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }

        self.commandQueue = queue
        self.pipelineState = state
        self.sampler = samplerState
        self.stream = stream

        super.init()

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(sampler, index: 0)

        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        var eyeAspect: Float = 1
        texture = nil

        if !showTestPattern, let pixelBuffer = stream?.currentBuffer() {
            texture = makeTexture(from: pixelBuffer)
            let width = Float(CVPixelBufferGetWidth(pixelBuffer)) * 0.5
            let height = Float(CVPixelBufferGetHeight(pixelBuffer))
            if width > 0, height > 0 {
                eyeAspect = width / height
            }
        }

        let mode: Float = texture == nil ? 1 : 0
        if mode > 0.5 { eyeAspect = 1 }

        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
        }

        var uniforms = QuadUniforms()
        uniforms.k = SIMD2<Float>(distortionK1, distortionK2)
        uniforms.chroma = chromaticAberration
        uniforms.brightness = brightness
        uniforms.saturation = saturation
        uniforms.vignette = vignette
        uniforms.mode = mode
        uniforms.aspect = eyeAspect

        for eye in 0..<2 {
            let vertices = quadVertices(eye: eye, drawableSize: size, aspect: eyeAspect)
            uniforms.eyeIndex = Float(eye)
            encoder.setVertexBytes(vertices,
                                   length: MemoryLayout<QuadVertex>.stride * vertices.count,
                                   index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Helpers

    /// Lays one eye's image out in its half of the screen, keeping the source
    /// aspect ratio so faces and text are not stretched.
    private func quadVertices(eye: Int, drawableSize: CGSize, aspect: Float) -> [QuadVertex] {
        let width = Float(drawableSize.width)
        let height = Float(drawableSize.height)
        let halfWidth = width * 0.5

        var fitWidth = halfWidth
        var fitHeight = height
        if aspect > 0 {
            if halfWidth / height > aspect {
                fitWidth = height * aspect
            } else {
                fitHeight = halfWidth / aspect
            }
        }

        let originX = Float(eye) * halfWidth + (halfWidth - fitWidth) * 0.5
        let originY = (height - fitHeight) * 0.5

        let x0 = -1 + 2 * originX / width
        let x1 = -1 + 2 * (originX + fitWidth) / width
        let yBottom = 1 - 2 * (originY + fitHeight) / height
        let yTop = 1 - 2 * originY / height

        return [
            QuadVertex(position: SIMD2<Float>(x0, yBottom), uv: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(x1, yBottom), uv: SIMD2<Float>(1, 1)),
            QuadVertex(position: SIMD2<Float>(x0, yTop), uv: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(x1, yTop), uv: SIMD2<Float>(1, 0))
        ]
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              textureCache,
                                                              pixelBuffer,
                                                              nil,
                                                              .bgra8Unorm,
                                                              width,
                                                              height,
                                                              0,
                                                              &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}
