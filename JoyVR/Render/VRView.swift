//
//  VRView.swift
//  JoyVR
//

import MetalKit
import SwiftUI

struct VRView: UIViewRepresentable {
    let pipeline: StreamPipeline
    let testPattern: Bool
    let picture: PictureTuning

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero)
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = StereoRenderer(device: device, stream: pipeline) else {
            view.clearColor = MTLClearColorMake(0, 0, 0, 1)
            return view
        }

        apply(picture, testPattern: testPattern, to: renderer)
        context.coordinator.renderer = renderer

        view.device = device
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.02, 0.02, 0.03, 1)
        view.framebufferOnly = true
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 90
        view.autoResizeDrawable = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        apply(picture, testPattern: testPattern, to: renderer)
    }

    private func apply(_ picture: PictureTuning, testPattern: Bool, to renderer: StereoRenderer) {
        renderer.showTestPattern = testPattern
        renderer.distortionK1 = picture.distortionK1
        renderer.distortionK2 = picture.distortionK2
        renderer.chromaticAberration = picture.chromaticAberration
        renderer.brightness = picture.brightness
        renderer.saturation = picture.saturation
        renderer.vignette = picture.vignette
    }

    final class Coordinator {
        var renderer: StereoRenderer?
    }
}
