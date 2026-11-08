//
//  PoseMath.swift
//  JoyVR
//
//  One pose, in the convention OpenVR expects: right handed, +Y up,
//  looking down -Z, metres.
//

import Foundation
import simd

struct PoseSnapshot {
    var orientation = simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0))
    var position = SIMD3<Float>(0, 0, 0)
    var angularVelocity = SIMD3<Float>(0, 0, 0)
    var timestampUs: UInt64 = 0
    var isSixDOF = false
}

enum PoseMath {
    /// CoreMotion reports attitude in a Z-up frame. Rotating by -90° about X
    /// turns its +Z into our +Y, so the device's -Z (out of the back of the
    /// phone) becomes "forward".
    static let zUpToYUp = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

    static func normalized(_ q: simd_quatf) -> simd_quatf {
        let magnitude = sqrt(q.real * q.real + simd_length_squared(q.imag))
        guard magnitude > 0.0001 else {
            return simd_quatf(real: 1, imag: SIMD3<Float>(0, 0, 0))
        }
        return simd_quatf(real: q.real / magnitude, imag: q.imag / magnitude)
    }

    /// Heading of the pose on the horizontal plane, in radians.
    static func yaw(of q: simd_quatf) -> Float {
        let forward = q.act(SIMD3<Float>(0, 0, -1))
        return atan2(forward.x, -forward.z)
    }

    static func yawRotation(_ angle: Float) -> simd_quatf {
        simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
    }

    static func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }

    /// A rotation whose local -Z points along `forward`, rolled so local +Y is
    /// as close to `up` as it can be.
    static func rotation(forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        var forwardAxis = forward
        if simd_length(forwardAxis) < 0.0001 {
            forwardAxis = SIMD3<Float>(0, 0, -1)
        }
        forwardAxis = simd_normalize(forwardAxis)

        let zAxis = -forwardAxis

        var upAxis = up - forwardAxis * simd_dot(up, forwardAxis)
        if simd_length(upAxis) < 0.0001 {
            upAxis = SIMD3<Float>(0, 1, 0) - forwardAxis * forwardAxis.y
            if simd_length(upAxis) < 0.0001 {
                upAxis = SIMD3<Float>(1, 0, 0)
            }
        }
        upAxis = simd_normalize(upAxis)

        var xAxis = simd_cross(upAxis, zAxis)
        if simd_length(xAxis) < 0.0001 {
            xAxis = SIMD3<Float>(1, 0, 0)
        }
        xAxis = simd_normalize(xAxis)

        let yAxis = simd_cross(zAxis, xAxis)
        return quaternion(basisX: xAxis, basisY: yAxis, basisZ: zAxis)
    }

    /// Rotation matrix, given as three basis vectors, to a quaternion.
    static func quaternion(basisX: SIMD3<Float>,
                           basisY: SIMD3<Float>,
                           basisZ: SIMD3<Float>) -> simd_quatf {
        let m00 = basisX.x, m10 = basisX.y, m20 = basisX.z
        let m01 = basisY.x, m11 = basisY.y, m21 = basisY.z
        let m02 = basisZ.x, m12 = basisZ.y, m22 = basisZ.z

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
