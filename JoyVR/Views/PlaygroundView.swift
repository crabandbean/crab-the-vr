//
//  PlaygroundView.swift
//  JoyVR
//
//  What goes on inside the box when no PC is linked: a wireframe room to look
//  around in, the camera's hands in 3D, and a live picture of the controller in
//  your hands. Nothing here needs a PC.
//

import SwiftUI
import simd

struct PlaygroundView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gamepad: GamepadTracker
    @EnvironmentObject private var hands: HandTracker

    private let ipd: Float = 0.064
    private let verticalFOV: Float = 90 * .pi / 180

    private static let handBones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (0, 9), (9, 10), (10, 11), (11, 12),
        (0, 13), (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20),
        (5, 9), (9, 13), (13, 17)
    ]

    private static let cubeEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7)
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0)) { _ in
            Canvas { context, size in
                render(&context, size: size)
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    // MARK: Scene

    private func render(_ context: inout GraphicsContext, size: CGSize) {
        let pose = model.headTracker.current
        let eyeWidth = size.width / 2
        let focal = Float(eyeWidth * 0.5) / tan(verticalFOV / 2)

        for eye in 0..<2 {
            let offset = SIMD3<Float>(eye == 0 ? -ipd / 2 : ipd / 2, 0, 0)
            let rect = CGRect(x: CGFloat(eye) * eyeWidth, y: 0, width: eyeWidth, height: size.height)
            let projection = EyeProjection(pose: pose, eyeOffset: offset, rect: rect, focal: focal)
            drawScene(&context, projection)
        }
    }

    private func drawScene(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        drawFloor(&context, eye)
        drawLandmarks(&context, eye)
        drawHands(&context, eye)
        drawController(&context, eye)
        drawHints(&context, eye)
    }

    private func drawFloor(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        let y: Float = -1.6
        let near: Float = -0.4
        let far: Float = -6.0

        var faint = Path()
        var strong = Path()

        for index in -8...8 {
            let x = Float(index) * 0.5
            if let a = eye.point(SIMD3<Float>(x, y, near)),
               let b = eye.point(SIMD3<Float>(x, y, far)) {
                faint.move(to: a)
                faint.addLine(to: b)
            }
        }

        for index in 0...12 {
            let z = near - Float(index) * 0.5
            if let a = eye.point(SIMD3<Float>(-4, y, z)),
               let b = eye.point(SIMD3<Float>(4, y, z)) {
                faint.move(to: a)
                faint.addLine(to: b)
            }
        }

        // A brighter ring around where the player is standing.
        for index in 0..<48 {
            let angle = Float(index) / 48 * 2 * .pi
            let next = Float(index + 1) / 48 * 2 * .pi
            if let a = eye.point(SIMD3<Float>(sin(angle) * 1.2, y + 0.002, -1.2 + cos(angle) * 1.2)),
               let b = eye.point(SIMD3<Float>(sin(next) * 1.2, y + 0.002, -1.2 + cos(next) * 1.2)) {
                strong.move(to: a)
                strong.addLine(to: b)
            }
        }

        context.stroke(faint, with: .color(Theme.accent.opacity(0.16)), lineWidth: 1)
        context.stroke(strong, with: .color(Theme.accent.opacity(0.5)), lineWidth: 1.5)
    }

    private func drawLandmarks(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        let floor: Float = -1.6
        let boxes: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3<Float>(-1.7, floor + 0.3, -2.6), SIMD3<Float>(0.6, 0.6, 0.6)),
            (SIMD3<Float>(1.6, floor + 0.45, -3.2), SIMD3<Float>(0.9, 0.9, 0.9)),
            (SIMD3<Float>(0.2, floor + 0.18, -4.2), SIMD3<Float>(1.4, 0.36, 0.4))
        ]

        for (center, size) in boxes {
            let half = size / 2
            let corners = [
                center + SIMD3<Float>(-half.x, -half.y, -half.z),
                center + SIMD3<Float>(half.x, -half.y, -half.z),
                center + SIMD3<Float>(half.x, -half.y, half.z),
                center + SIMD3<Float>(-half.x, -half.y, half.z),
                center + SIMD3<Float>(-half.x, half.y, -half.z),
                center + SIMD3<Float>(half.x, half.y, -half.z),
                center + SIMD3<Float>(half.x, half.y, half.z),
                center + SIMD3<Float>(-half.x, half.y, half.z)
            ]

            var path = Path()
            for (a, b) in Self.cubeEdges {
                if let p = eye.point(corners[a]), let q = eye.point(corners[b]) {
                    path.move(to: p)
                    path.addLine(to: q)
                }
            }
            context.stroke(path, with: .color(Theme.accent.opacity(0.28)), lineWidth: 1.2)
        }
    }

    private func drawHands(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        for hand in hands.overlayHands where hand.joints3D.count == 21 {
            let color = hand.chirality == .left
                ? Theme.accent
                : Color(red: 0.55, green: 0.75, blue: 1.0)

            for (a, b) in Self.handBones {
                guard let p = eye.point(hand.joints3D[a]), let q = eye.point(hand.joints3D[b]) else { continue }
                var path = Path()
                path.move(to: p)
                path.addLine(to: q)
                context.stroke(path,
                               with: .color(color.opacity(0.85 * hand.opacity)),
                               lineWidth: 2)
            }

            for joint in hand.joints3D {
                guard let point = eye.point(joint) else { continue }
                let radius: CGFloat = 1.6
                let rect = CGRect(x: point.x - radius, y: point.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(hand.opacity)))
            }
        }
    }

    private func drawController(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        guard let pad = gamepad.primaryPad else { return }

        let snapshot = gamepad.snapshot(for: pad.id)
        let anchor = SIMD3<Float>(0.20, -0.30, -0.55)
        guard let center = eye.point(anchor) else { return }

        let width = eye.scale(0.40, at: anchor)
        let height = width * 0.60
        let rect = CGRect(x: center.x - width / 2,
                          y: center.y - height / 2,
                          width: width,
                          height: height)

        let body = Path(roundedRect: rect, cornerRadius: width * 0.07)
        context.fill(body, with: .color(Color.black.opacity(0.4)))
        context.stroke(body, with: .color(.white.opacity(0.14)), lineWidth: 1)

        let title = Text(pad.name)
            .font(.system(size: max(7, height * 0.13), weight: .semibold))
            .foregroundColor(.white.opacity(0.85))
        context.draw(title, at: CGPoint(x: rect.minX + width * 0.08, y: rect.minY + height * 0.18), anchor: .leading)

        // Sticks.
        drawStick(&context, in: rect, x: 0.22, y: 0.58, value: snapshot.leftStick, label: "L")
        drawStick(&context, in: rect, x: 0.42, y: 0.58, value: snapshot.rightStick, label: "R")

        // A, B, X, Y.
        drawFaceButton(&context, in: rect, x: 0.72, y: 0.42, label: "X", pressed: snapshot.buttons.contains(.x))
        drawFaceButton(&context, in: rect, x: 0.66, y: 0.58, label: "Y", pressed: snapshot.buttons.contains(.y))
        drawFaceButton(&context, in: rect, x: 0.78, y: 0.58, label: "A", pressed: snapshot.buttons.contains(.a))
        drawFaceButton(&context, in: rect, x: 0.72, y: 0.74, label: "B", pressed: snapshot.buttons.contains(.b))

        // ZL and ZR as two little fill bars.
        drawBar(&context, in: rect, x: 0.08, y: 0.86, width: 0.36, value: snapshot.leftTrigger, label: "ZL")
        drawBar(&context, in: rect, x: 0.56, y: 0.86, width: 0.36, value: snapshot.rightTrigger, label: "ZR")
    }

    private func drawStick(_ context: inout GraphicsContext,
                           in rect: CGRect,
                           x: CGFloat,
                           y: CGFloat,
                           value: SIMD2<Float>,
                           label: String) {
        let radius = rect.height * 0.15
        let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
        context.stroke(circle, with: .color(.white.opacity(0.25)), lineWidth: 1)

        let dotRadius = max(1.5, radius * 0.28)
        let dotX = center.x + CGFloat(max(-1, min(1, value.x))) * radius * 0.55
        let dotY = center.y - CGFloat(max(-1, min(1, value.y))) * radius * 0.55
        let dot = Path(ellipseIn: CGRect(x: dotX - dotRadius, y: dotY - dotRadius,
                                         width: dotRadius * 2, height: dotRadius * 2))
        context.fill(dot, with: .color(Theme.accent))

        context.draw(Text(label)
                        .font(.system(size: max(6, rect.height * 0.10), weight: .semibold))
                        .foregroundColor(.white.opacity(0.5)),
                     at: CGPoint(x: center.x, y: center.y + radius + rect.height * 0.08))
    }

    private func drawFaceButton(_ context: inout GraphicsContext,
                                in rect: CGRect,
                                x: CGFloat,
                                y: CGFloat,
                                label: String,
                                pressed: Bool) {
        let radius = rect.height * 0.08
        let center = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(pressed ? Theme.accent : Color.white.opacity(0.12)))
        context.draw(Text(label)
                        .font(.system(size: max(5, rect.height * 0.10), weight: .bold))
                        .foregroundColor(pressed ? .black.opacity(0.8) : .white.opacity(0.7)),
                     at: center)
    }

    private func drawBar(_ context: inout GraphicsContext,
                         in rect: CGRect,
                         x: CGFloat,
                         y: CGFloat,
                         width: CGFloat,
                         value: Float,
                         label: String) {
        let barWidth = rect.width * width
        let barHeight = max(2, rect.height * 0.05)
        let origin = CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)

        context.draw(Text(label)
                        .font(.system(size: max(6, rect.height * 0.09), weight: .semibold))
                        .foregroundColor(.white.opacity(0.5)),
                     at: CGPoint(x: origin.x + 6, y: rect.minY + rect.height * y - rect.height * 0.06),
                     anchor: .bottomLeading)

        let background = Path(roundedRect: CGRect(x: origin.x, y: origin.y,
                                                  width: barWidth, height: CGFloat(barHeight)),
                              cornerRadius: CGFloat(barHeight / 2))
        context.fill(background, with: .color(.white.opacity(0.12)))

        let filled = max(1, CGFloat(max(0, min(1, value))) * CGFloat(rect.width * width))
        let fill = Path(roundedRect: CGRect(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y,
                                            width: filled, height: CGFloat(barHeight)),
                        cornerRadius: CGFloat(barHeight / 2))
        context.fill(fill, with: .color(Theme.accent.opacity(0.85)))
    }

    private func drawHints(_ context: inout GraphicsContext, _ eye: EyeProjection) {
        var lines: [String] = []
        if !ARKitHeadSource.isSupported {
            lines.append("Hand tracking needs a real iPhone camera.")
        } else if !model.settings.handTrackingEnabled {
            lines.append("Turn on See your hands in Settings to see hands here.")
        } else if hands.overlayHands.isEmpty {
            lines.append("Hands: nothing in view — hold them in front of the box's camera window.")
        }
        if gamepad.primaryPad == nil {
            lines.append("Controller: none paired — pair one in Settings › Bluetooth.")
        }

        for (index, line) in lines.enumerated() {
            let text = Text(line)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            context.draw(text,
                         at: CGPoint(x: eye.rect.midX, y: eye.rect.maxY - 46 - CGFloat(index) * 15))
        }
    }
}

// MARK: - Projection

private struct EyeProjection {
    let headPosition: SIMD3<Float>
    let headOrientation: simd_quatf
    let eyePosition: SIMD3<Float>
    let focal: Float
    let rect: CGRect

    init(pose: PoseSnapshot, eyeOffset: SIMD3<Float>, rect: CGRect, focal: Float) {
        headPosition = pose.position
        headOrientation = pose.orientation
        eyePosition = pose.position + pose.orientation.act(eyeOffset)
        self.rect = rect
        self.focal = focal
    }

    func point(_ headLocal: SIMD3<Float>) -> CGPoint? {
        let world = headPosition + headOrientation.act(headLocal)
        let local = headOrientation.inverse.act(world - eyePosition)
        guard local.z < -0.03 else { return nil }
        let x = rect.midX + CGFloat(local.x / -local.z) * CGFloat(focal)
        let y = rect.midY - CGFloat(local.y / -local.z) * CGFloat(focal)
        return CGPoint(x: x, y: y)
    }

    func scale(_ meters: Float, at headLocal: SIMD3<Float>) -> CGFloat {
        let world = headPosition + headOrientation.act(headLocal)
        let local = headOrientation.inverse.act(world - eyePosition)
        let depth = max(0.05, -local.z)
        return CGFloat(meters / depth * focal)
    }
}
