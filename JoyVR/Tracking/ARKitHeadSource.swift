//
//  ARKitHeadSource.swift
//  JoyVR
//
//  ARKit world tracking, kept to one job: where the phone is in the room. The
//  pose is already in the OpenVR convention (right handed, +Y up, looking down
//  -Z) so the gyro pose and this one can be fused without converting frames.
//

import ARKit
import Foundation
import simd

struct ARHeadSample {
    var position = SIMD3<Float>(0, 0, 0)
    var orientation = simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0))
    var isTracked = false
    var quality: Float = 0
    var note = ""
    var timestamp: TimeInterval = 0
}

final class ARKitHeadSource: NSObject, ARSessionDelegate {

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private(set) var session = ARSession()

    private let lock = NSLock()
    private var storage: ARHeadSample?
    private var running = false

    var isSupported: Bool { Self.isSupported }

    /// Every camera frame, for whoever needs pixels (hand tracking).
    var onFrame: ((ARFrame) -> Void)?

    var latest: ARHeadSample? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    // MARK: Running

    private func makeConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    func start() {
        guard Self.isSupported else {
            store(ARHeadSample(isTracked: false,
                               quality: 0,
                               note: "This iPhone cannot see the room",
                               timestamp: 0))
            return
        }
        guard !running else { return }

        session.delegate = self
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        running = true
    }

    func stop() {
        guard running else { return }
        session.pause()
        running = false
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let transform = camera.transform

        let (tracked, quality, note) = Self.describe(camera.trackingState)

        var sample = ARHeadSample()
        sample.position = SIMD3<Float>(transform.columns.3.x,
                                       transform.columns.3.y,
                                       transform.columns.3.z)
        sample.orientation = Self.quaternion(fromRotationOf: transform)
        sample.isTracked = tracked
        sample.quality = quality
        sample.note = note
        sample.timestamp = frame.timestamp
        store(sample)
        onFrame?(frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        var note = "Visual tracking stopped"
        if let arError = error as? ARError {
            switch arError.code {
            case .cameraUnauthorized:
                note = "Camera access is off — allow it in Settings"
            case .unsupportedConfiguration:
                note = "This iPhone cannot see the room"
            default:
                note = "Visual tracking stopped"
            }
        }
        store(ARHeadSample(isTracked: false, quality: 0, note: note, timestamp: 0))
        running = false
    }

    func sessionWasInterrupted(_ session: ARSession) {
        store(ARHeadSample(isTracked: false, quality: 0, note: "Camera interrupted", timestamp: 0))
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        guard running else { return }
        session.run(makeConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: Helpers

    private func store(_ sample: ARHeadSample) {
        lock.lock()
        storage = sample
        lock.unlock()
    }

    private static func describe(_ state: ARCamera.TrackingState) -> (Bool, Float, String) {
        switch state {
        case .normal:
            return (true, 1.0, "Room in view")
        case .limited(let reason):
            switch reason {
            case .initializing:
                return (false, 0.35, "Move the box slowly")
            case .excessiveMotion:
                return (false, 0.25, "Moving too fast")
            case .insufficientFeatures:
                return (false, 0.25, "Needs more light or detail")
            case .relocalizing:
                return (false, 0.2, "Re-locating the room")
            @unknown default:
                return (false, 0.2, "Visual tracking is limited")
            }
        case .notAvailable:
            return (false, 0.0, "The camera cannot see the room")
        }
    }

    /// Rotation matrix to quaternion, in x, y, z, w order.
    private static func quaternion(fromRotationOf matrix: simd_float4x4) -> simd_quatf {
        let c0 = matrix.columns.0
        let c1 = matrix.columns.1
        let c2 = matrix.columns.2

        let m00 = c0.x, m10 = c0.y, m20 = c0.z
        let m01 = c1.x, m11 = c1.y, m21 = c1.z
        let m02 = c2.x, m12 = c2.y, m22 = c2.z

        let trace = m00 + m11 + m22
        var q = SIMD4<Float>(0, 0, 0, 1)

        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = SIMD4<Float>((m21 - m12) / s,
                             (m02 - m20) / s,
                             (m10 - m01) / s,
                             0.25 * s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            q = SIMD4<Float>(0.25 * s,
                             (m01 + m10) / s,
                             (m02 + m20) / s,
                             (m21 - m12) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            q = SIMD4<Float>((m01 + m10) / s,
                             0.25 * s,
                             (m12 + m21) / s,
                             (m02 - m20) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            q = SIMD4<Float>((m02 + m20) / s,
                             (m12 + m21) / s,
                             0.25 * s,
                             (m10 - m01) / s)
        }

        let length = (q * q).sum().squareRoot()
        guard length > 0.0001 else {
            return simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0))
        }
        q /= length
        return simd_quatf(real: q.w, imag: SIMD3<Float>(q.x, q.y, q.z))
    }
}
