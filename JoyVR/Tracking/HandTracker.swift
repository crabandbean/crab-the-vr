//
//  HandTracker.swift
//  JoyVR
//
//  Up to two hands from the camera, with Vision. Each hand becomes a grip and
//  an aim pose plus 21 finger joints, all in the head's own frame, so the PC can
//  use it like a tracked controller.
//

import ARKit
import Combine
import CoreVideo
import Foundation
import Vision
import simd

struct HandPose {
    enum Chirality: UInt8, CaseIterable {
        case left = 0
        case right = 1
    }

    /// Vision's 21 joints, in the order the PC reads them.
    static let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    static let wrist = 0
    static let thumbTip = 4
    static let indexTip = 8
    static let indexMCP = 5
    static let middleMCP = 9
    static let ringMCP = 13
    static let littleMCP = 17

    var chirality: Chirality
    /// 21 positions in metres, in the head's frame.
    var joints: [SIMD3<Float>]
    /// The same joints in Vision's normalised image space, for the overlay.
    var normalizedJoints: [SIMD2<Float>]
    var gripPosition: SIMD3<Float>
    var gripOrientation: simd_quatf
    var aimPosition: SIMD3<Float>
    var aimOrientation: simd_quatf
    var pinch: Float
    var confidence: Float
    var depthFromSensor: Bool
    var timestamp: CFTimeInterval
}

final class HandTracker: ObservableObject {

    struct OverlayHand: Identifiable, Equatable {
        let id: UInt8
        var chirality: HandPose.Chirality
        var joints: [SIMD2<Float>]
        /// The same joints in the head's frame, for the 3D playground.
        var joints3D: [SIMD3<Float>]
        var opacity: Double
        var pinch: Float
    }

    @Published private(set) var overlayHands: [OverlayHand] = []

    private weak var source: ARKitHeadSource?
    private let visionQueue = DispatchQueue(label: "com.joyvr.hands", qos: .userInitiated)
    private let request = VNDetectHumanHandPoseRequest()
    private let lock = NSLock()
    private var poses: [HandPose] = []
    private var lastFrameHandled: CFTimeInterval = 0

    // Overlay state, main thread only.
    private var overlayStorage: [UInt8: (hand: OverlayHand, seen: CFTimeInterval)] = [:]
    private var fadeTimer: Timer?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }

            if isEnabled {
                request.maximumHandCount = 2
                source?.onFrame = { [weak self] frame in
                    self?.handle(frame)
                }
                startFadeTimer()
            } else {
                source?.onFrame = nil
                stopFadeTimer()
                clear()
            }
        }
    }

    deinit {
        fadeTimer?.invalidate()
    }

    /// Hands ride on the head tracker's camera session.
    func attach(to source: ARKitHeadSource) {
        self.source = source
        if isEnabled {
            source.onFrame = { [weak self] frame in
                self?.handle(frame)
            }
        }
    }

    /// What goes in the pose packet, hands that were seen a moment ago.
    var forwardedHands: [PhonePacket.Hand] {
        let now = CACurrentMediaTime()
        lock.lock()
        let current = poses
        lock.unlock()

        return current
            .filter { now - $0.timestamp < 0.35 }
            .map { pose in
                PhonePacket.Hand(chirality: pose.chirality.rawValue,
                                 flags: 1 | (pose.depthFromSensor ? 2 : 0),
                                 confidence: UInt8(clamping: Int((max(0, min(1, pose.confidence)) * 255).rounded())),
                                 pinch: UInt16(clamping: Int((max(0, min(1, pose.pinch)) * 65535).rounded())),
                                 gripPosition: pose.gripPosition,
                                 gripRotation: pose.gripOrientation,
                                 aimPosition: pose.aimPosition,
                                 aimRotation: pose.aimOrientation,
                                 joints: pose.joints)
            }
    }

    // MARK: Camera frames

    private func handle(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        guard now - lastFrameHandled >= 0.05 else { return }
        lastFrameHandled = now

        visionQueue.async { [weak self] in
            self?.detect(in: frame)
        }
    }

    private func detect(in frame: ARFrame) {
        autoreleasepool {
            // The raw camera frame is already in the phone's own frame (which
            // is landscape in the box), so Vision's points line up with the
            // ARKit intrinsics without another rotation.
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage,
                                                orientation: .up,
                                                options: [:])
            do {
                try handler.perform([request])
            } catch {
                publish([], overlay: [])
                return
            }

            guard let results = request.results else {
                publish([], overlay: [])
                return
            }

            var newPoses: [HandPose] = []
            var overlays: [OverlayHand] = []
            for observation in results {
                guard let pose = makePose(from: observation, frame: frame) else { continue }
                newPoses.append(pose)
                overlays.append(OverlayHand(id: pose.chirality.rawValue,
                                            chirality: pose.chirality,
                                            joints: pose.normalizedJoints,
                                            joints3D: pose.joints,
                                            opacity: 1,
                                            pinch: pose.pinch))
            }
            publish(newPoses, overlay: overlays)
        }
    }

    private func publish(_ newPoses: [HandPose], overlay: [OverlayHand]) {
        let now = CACurrentMediaTime()

        lock.lock()
        poses = newPoses
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var result: [OverlayHand] = []
            for hand in overlay {
                self.overlayStorage[hand.id] = (hand, now)
                result.append(hand)
            }
            self.overlayHands = result.sorted { $0.id < $1.id }
        }
    }

    private func clear() {
        lock.lock()
        poses = []
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.overlayStorage = [:]
            self?.overlayHands = []
        }
    }

    // MARK: Fading out

    private func startFadeTimer() {
        stopFadeTimer()
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.tickFade()
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func tickFade() {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        var changed = false
        var result: [OverlayHand] = []

        for (id, entry) in overlayStorage {
            let age = now - entry.seen
            let opacity = max(0, 1 - age / 0.45)
            if opacity <= 0.02 {
                overlayStorage.removeValue(forKey: id)
                changed = true
                continue
            }
            var hand = entry.hand
            if abs(hand.opacity - opacity) > 0.01 {
                hand.opacity = opacity
                overlayStorage[id] = (hand, entry.seen)
                changed = true
            }
            result.append(hand)
        }

        result.sort { $0.id < $1.id }
        if changed || result.map(\.id) != overlayHands.map(\.id) {
            overlayHands = result
        }
    }

    // MARK: Turning Vision into a hand pose

    private func makePose(from observation: VNHumanHandPoseObservation, frame: ARFrame) -> HandPose? {
        guard let points = try? observation.recognizedPoints(.all),
              let wristPoint = points[.wrist] else { return nil }

        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imageSize = camera.imageResolution
        let fx = intrinsics.columns.0.x
        guard fx > 1 else { return nil }

        var handDepth = depth(at: wristPoint.location, in: frame.sceneDepth)
        let usedSensor = handDepth != nil
        if handDepth == nil {
            handDepth = estimatedDepth(points: points, fx: fx, imageSize: imageSize)
        }
        guard let depth = handDepth else { return nil }

        var joints = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0),
                                    count: HandPose.jointNames.count)
        var normalized = [SIMD2<Float>](repeating: SIMD2<Float>(Float(wristPoint.location.x),
                                                                Float(wristPoint.location.y)),
                                        count: HandPose.jointNames.count)
        var confidenceTotal: Float = 0
        var confidenceCount: Float = 0

        for (index, name) in HandPose.jointNames.enumerated() {
            guard let point = points[name], point.confidence > 0.1 else { continue }
            joints[index] = cameraPosition(normalized: point.location,
                                           depth: depth,
                                           intrinsics: intrinsics,
                                           imageSize: imageSize)
            normalized[index] = SIMD2<Float>(Float(point.location.x), Float(point.location.y))
            confidenceTotal += point.confidence
            confidenceCount += 1
        }
        guard confidenceCount > 0 else { return nil }

        // Missing joints borrow the wrist, so the skeleton still draws.
        let wrist = joints[HandPose.wrist]
        for index in joints.indices where simd_length(joints[index]) < 0.0001 {
            joints[index] = wrist
        }

        let palm = (joints[HandPose.indexMCP] +
                    joints[HandPose.middleMCP] +
                    joints[HandPose.ringMCP] +
                    joints[HandPose.littleMCP]) / 4
        let middle = joints[HandPose.middleMCP]

        let forward = middle - wrist
        guard simd_length(forward) > 0.001 else { return nil }

        let upGuess = simd_cross(joints[HandPose.indexMCP] - joints[HandPose.littleMCP],
                                 wrist - middle)
        let up = simd_length(upGuess) > 0.0001 ? simd_normalize(upGuess) : SIMD3<Float>(0, 1, 0)
        let rotation = PoseMath.rotation(forward: forward, up: up)

        let handLength = simd_distance(wrist, middle)
        var pinch: Float = 0
        let thumb = joints[HandPose.thumbTip]
        let indexTip = joints[HandPose.indexTip]
        if simd_length(thumb) > 0.0001, simd_length(indexTip) > 0.0001 {
            let gap = simd_distance(thumb, indexTip)
            pinch = max(0, min(1, 1 - gap / max(0.02, handLength * 0.9)))
        }

        let chirality: HandPose.Chirality
        switch observation.chirality {
        case .left: chirality = .left
        case .right: chirality = .right
        @unknown default: chirality = .right
        }

        return HandPose(chirality: chirality,
                        joints: joints,
                        normalizedJoints: normalized,
                        gripPosition: palm,
                        gripOrientation: rotation,
                        aimPosition: wrist + simd_normalize(forward) * 0.04,
                        aimOrientation: rotation,
                        pinch: pinch,
                        confidence: confidenceTotal / confidenceCount,
                        depthFromSensor: usedSensor,
                        timestamp: CACurrentMediaTime())
    }

    private func cameraPosition(normalized: CGPoint,
                                depth: Float,
                                intrinsics: simd_float3x3,
                                imageSize: CGSize) -> SIMD3<Float> {
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x
        let cy = intrinsics.columns.2.y
        guard fx > 0, fy > 0 else { return SIMD3<Float>(0, 0, -depth) }

        let pixelX = Float(normalized.x) * Float(imageSize.width)
        let pixelY = (1 - Float(normalized.y)) * Float(imageSize.height)

        let cameraX = (pixelX - cx) / fx * depth
        let cameraY = (pixelY - cy) / fy * depth

        // The pinhole gives y down and z forward; ARKit's camera axes are y up
        // and z back, which is also the head's frame in our pose.
        return SIMD3<Float>(cameraX, -cameraY, -depth)
    }

    private func estimatedDepth(points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
                                fx: Float,
                                imageSize: CGSize) -> Float? {
        let pairs: [(VNHumanHandPoseObservation.JointName,
                     VNHumanHandPoseObservation.JointName,
                     Float)] = [
            (.wrist, .middleMCP, 0.085),
            (.indexMCP, .littleMCP, 0.075),
            (.thumbTip, .littleMCP, 0.13)
        ]

        var estimates: [Float] = []
        for (near, far, realLength) in pairs {
            guard let a = points[near], let b = points[far] else { continue }
            let dx = (Float(a.location.x) - Float(b.location.x)) * Float(imageSize.width)
            let dy = (Float(a.location.y) - Float(b.location.y)) * Float(imageSize.height)
            let pixels = sqrt(dx * dx + dy * dy)
            if pixels > 2 {
                estimates.append(fx * realLength / pixels)
            }
        }

        guard !estimates.isEmpty else { return 0.5 }
        let mean = estimates.reduce(0, +) / Float(estimates.count)
        return min(3, max(0.15, mean))
    }

    private func depth(at normalized: CGPoint, in depthData: ARDepthData?) -> Float? {
        guard let depthData else { return nil }
        let depthMap = depthData.depthMap

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0 else { return nil }

        let x = min(width - 1, max(0, Int(CGFloat(normalized.x) * CGFloat(width))))
        let y = min(height - 1, max(0, Int((1 - CGFloat(normalized.y)) * CGFloat(height))))

        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
        let value = row[x]

        guard value.isFinite, value > 0.05, value < 5 else { return nil }
        return Float(value)
    }
}
