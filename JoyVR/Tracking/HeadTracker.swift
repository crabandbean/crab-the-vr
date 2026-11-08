//
//  HeadTracker.swift
//  JoyVR
//
//  Head rotation from the gyro, position from ARKit's world tracking, fused
//  into the pose of a phone sitting inside a headset. When the camera loses the
//  room the gyro keeps the view turning and the position holds still.
//

import CoreMotion
import Foundation
import simd

final class HeadTracker {
    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.joyvr.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// Visual tracking, polled from the motion queue.
    let visual = ARKitHeadSource()

    private let lock = NSLock()
    private var storage = PoseSnapshot()
    private var statusStorage = HeadTrackingStatus()
    private var recenterYaw: Float?

    // Set from the app, read on the motion queue. Protected by `lock`.
    private var sixDOF = true
    private var smoothing: Float = 0.4
    private var pendingRecenter = true
    private var pendingVisualRebase = true
    private var pendingEyeLevel = false

    // Fusion state: only touched on the motion queue, under `lock`.
    private var visualOrigin: SIMD3<Float>?
    private var visualYaw: Float?
    private var visualTarget = SIMD3<Float>(0, 0, 0)
    private var filteredPosition = SIMD3<Float>(0, 0, 0)
    private var yawCorrection: Float = 0
    private var lastTimestamp: TimeInterval = 0

    var onPose: ((PoseSnapshot) -> Void)?
    var onStatus: ((HeadTrackingStatus) -> Void)?

    init() {
        statusStorage = HeadTrackingStatus(mode: .off,
                                           quality: 0,
                                           note: "Not running",
                                           isSupported: visual.isSupported)
    }

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    var current: PoseSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var status: HeadTrackingStatus {
        lock.lock()
        defer { lock.unlock() }
        return statusStorage
    }

    /// On: ARKit position plus gyro rotation. Off: rotation only.
    var isSixDOFEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return sixDOF
        }
        set {
            lock.lock()
            sixDOF = newValue
            if !newValue {
                visualOrigin = nil
                visualYaw = nil
                visualTarget = SIMD3<Float>(0, 0, 0)
                filteredPosition = SIMD3<Float>(0, 0, 0)
                yawCorrection = 0
            }
            lock.unlock()

            if newValue {
                if motionManager.isDeviceMotionActive {
                    visual.start()
                }
            } else if !handsEnabled {
                visual.stop()
            }
        }
    }

    /// 0 follows the head as closely as ARKit allows, 1 smooths small shakes.
    var stability: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return smoothing
        }
        set {
            lock.lock()
            smoothing = max(0, min(1, newValue))
            lock.unlock()
        }
    }

    /// Hand tracking needs the camera too, even when 6DoF is switched off.
    var handsEnabled = false {
        didSet {
            guard handsEnabled != oldValue else { return }
            if handsEnabled {
                if motionManager.isDeviceMotionActive {
                    visual.start()
                }
            } else if !isSixDOFEnabled {
                visual.stop()
            }
        }
    }

    // MARK: Running

    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            publish(HeadTrackingStatus(mode: .off,
                                       quality: 0,
                                       note: "Motion sensors unavailable",
                                       isSupported: visual.isSupported))
            return
        }

        lock.lock()
        let wantsSix = sixDOF
        lock.unlock()

        if !motionManager.isDeviceMotionActive {
            lock.lock()
            recenterYaw = nil
            pendingRecenter = true
            pendingVisualRebase = true
            pendingEyeLevel = false
            visualOrigin = nil
            visualYaw = nil
            visualTarget = SIMD3<Float>(0, 0, 0)
            filteredPosition = SIMD3<Float>(0, 0, 0)
            yawCorrection = 0
            lastTimestamp = 0
            lock.unlock()

            if wantsSix || handsEnabled { visual.start() }

            motionManager.deviceMotionUpdateInterval = 1.0 / 120.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                                   to: queue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                self.process(motion)
            }
        } else if wantsSix {
            visual.start()
        }
    }

    func stop() {
        visual.stop()
        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }

        lock.lock()
        recenterYaw = nil
        pendingRecenter = true
        pendingVisualRebase = true
        pendingEyeLevel = false
        visualOrigin = nil
        visualYaw = nil
        visualTarget = SIMD3<Float>(0, 0, 0)
        filteredPosition = SIMD3<Float>(0, 0, 0)
        yawCorrection = 0
        lastTimestamp = 0
        let stopped = HeadTrackingStatus(mode: .off,
                                         quality: 0,
                                         note: "Not running",
                                         isSupported: visual.isSupported)
        statusStorage = stopped
        lock.unlock()

        onStatus?(stopped)
    }

    // MARK: Calibration

    /// Re-aims the view: the way the head points now becomes forward.
    func recenter() {
        lock.lock()
        recenterYaw = nil
        pendingRecenter = true
        pendingVisualRebase = true
        lock.unlock()
    }

    /// First of the two setup taps: the height the head is at now becomes the
    /// height it plays at, so leaning and crouching start from here.
    func calibrateEyeLevel() {
        lock.lock()
        pendingEyeLevel = true
        lock.unlock()
    }

    /// Second tap: the way the box faces now becomes the game's forward.
    func calibrateForward() {
        recenter()
    }

    // MARK: Fusion

    private func process(_ motion: CMDeviceMotion) {
        let raw = motion.attitude.quaternion
        var core = simd_quatf(real: Float(raw.w),
                              imag: SIMD3<Float>(Float(raw.x),
                                                 Float(raw.y),
                                                 Float(raw.z)))
        core = PoseMath.normalized(PoseMath.zUpToYUp * core)

        lock.lock()

        let now = motion.timestamp
        let dt = lastTimestamp == 0 ? 0 : Float(min(max(now - lastTimestamp, 0), 0.05))
        lastTimestamp = now

        let heading = PoseMath.yaw(of: core)
        if pendingRecenter || recenterYaw == nil {
            recenterYaw = heading
            pendingRecenter = false
        }
        core = PoseMath.normalized(PoseMath.yawRotation(-(recenterYaw ?? 0)) * core)

        let sample = visual.latest
        let wantsSix = sixDOF && visual.isSupported
        let visualTracked = wantsSix && (sample?.isTracked ?? false)

        if pendingVisualRebase, let sample, sample.isTracked {
            visualOrigin = sample.position
            visualYaw = PoseMath.yaw(of: sample.orientation)
            visualTarget = SIMD3<Float>(0, 0, 0)
            yawCorrection = 0
            pendingVisualRebase = false
        }

        if pendingEyeLevel, let sample, sample.isTracked {
            var origin = visualOrigin ?? sample.position
            origin.y = sample.position.y
            visualOrigin = origin
            visualTarget.y = 0
            pendingEyeLevel = false
        }

        var orientation = core
        var mode: HeadTrackingStatus.Mode = .threeDOF
        var quality = sample?.quality ?? 0
        var note = "6DoF is off"

        if wantsSix {
            if visualTracked, let sample {
                if visualOrigin == nil { visualOrigin = sample.position }
                if visualYaw == nil { visualYaw = PoseMath.yaw(of: sample.orientation) }

                let origin = visualOrigin ?? sample.position
                let originYaw = visualYaw ?? 0
                let delta = sample.position - origin
                visualTarget = PoseMath.yawRotation(-originYaw).act(delta)

                // Follow ARKit's heading slowly, so the gyro keeps the high-rate
                // rotation and ARKit quietly takes care of the drift.
                let visualHeading = PoseMath.yaw(of: sample.orientation) - originYaw
                let coreHeading = PoseMath.yaw(of: core)
                let error = Self.wrappedAngle(visualHeading - coreHeading)
                let driftAlpha = Float(1 - exp(-Double(dt) / 1.5))
                yawCorrection += Self.wrappedAngle(error - yawCorrection) * driftAlpha
                yawCorrection = max(-0.6, min(0.6, yawCorrection))

                orientation = PoseMath.normalized(PoseMath.yawRotation(yawCorrection) * core)

                mode = .sixDOF
                quality = sample.quality
                note = sample.note
            } else {
                mode = .threeDOF
                quality = sample?.quality ?? 0
                note = (sample?.note.isEmpty == false) ? (sample?.note ?? "") : "Waiting for the camera"
            }
        } else {
            visualTarget = SIMD3<Float>(0, 0, 0)
            note = visual.isSupported ? "6DoF is off" : "This iPhone cannot see the room"
        }

        let tau = 0.02 + 0.4 * smoothing
        let alpha = dt > 0 ? Float(1 - exp(-Double(dt) / Double(tau))) : 0
        filteredPosition += (visualTarget - filteredPosition) * alpha
        if simd_length(filteredPosition) < 0.0005 {
            filteredPosition = SIMD3<Float>(0, 0, 0)
        }

        let rate = motion.rotationRate
        var snapshot = PoseSnapshot()
        snapshot.orientation = orientation
        snapshot.angularVelocity = orientation.act(SIMD3<Float>(Float(rate.x),
                                                                Float(rate.y),
                                                                Float(rate.z)))
        snapshot.timestampUs = PoseMath.nowMicroseconds()
        snapshot.position = filteredPosition
        snapshot.isSixDOF = mode == .sixDOF

        storage = snapshot

        let newStatus = HeadTrackingStatus(mode: mode,
                                           quality: quality,
                                           note: note,
                                           isSupported: visual.isSupported,
                                           isFallback: wantsSix && !visualTracked)
        let changed = newStatus != statusStorage
        if changed { statusStorage = newStatus }
        lock.unlock()

        onPose?(snapshot)
        if changed { onStatus?(newStatus) }
    }

    private func publish(_ status: HeadTrackingStatus) {
        lock.lock()
        statusStorage = status
        lock.unlock()
        onStatus?(status)
    }

    private static func wrappedAngle(_ angle: Float) -> Float {
        var value = angle
        while value > .pi { value -= 2 * .pi }
        while value < -.pi { value += 2 * .pi }
        return value
    }
}
