//
//  Protocol.swift
//  JoyVR
//
//  The wire format shared by the phone and the PC companion. Every packet is
//  little endian. See PC/PROTOCOL.md for the same table written out in prose.
//

import Foundation
import simd

enum JVRProtocol {
    static let version: UInt16 = 1

    /// UDP port the PC companion listens on for poses and hello packets.
    static let streamPort: UInt16 = 8930
    /// UDP port the PC companion listens on for discovery broadcasts.
    static let discoveryPort: UInt16 = 8931

    // Four byte ASCII markers.
    static let magicPose = Data([0x4A, 0x56, 0x52, 0x31])          // "JVR1"
    static let magicReply = Data([0x4A, 0x56, 0x52, 0x50])         // "JVRP"
    static let magicVideo = Data([0x4A, 0x56, 0x56, 0x31])         // "JVV1"
    static let magicDiscover = Data([0x4A, 0x56, 0x52, 0x51])      // "JVRQ"
    static let magicDiscoverReply = Data([0x4A, 0x56, 0x52, 0x45]) // "JVRE"

    static let packetPose: UInt16 = 1
    static let packetHello: UInt16 = 2
    static let packetBye: UInt16 = 3
    /// Round-trip probe; the PC echoes the timestamp.
    static let packetPing: UInt16 = 4
    /// A new bitrate for the encoder, in kilobits per second.
    static let packetBitrate: UInt16 = 5
    /// The lens and comfort profile the PC should render with.
    static let packetProfile: UInt16 = 6

    static let replyAck: UInt16 = 1
    static let replyStats: UInt16 = 2
    static let replyPong: UInt16 = 3

    /// Fixed part of every phone -> PC packet.
    static let phoneHeaderLength = 32
    /// Fixed part of a video datagram, before the payload.
    static let videoHeaderLength = 24
}

// MARK: - Little endian writers and readers

struct ByteWriter {
    private(set) var data = Data()

    mutating func append(_ other: Data) { data.append(other) }

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u16(_ value: UInt16) { appendInteger(value) }
    mutating func u32(_ value: UInt32) { appendInteger(value) }
    mutating func u64(_ value: UInt64) { appendInteger(value) }

    mutating func f32(_ value: Float) { appendInteger(value.bitPattern) }

    private mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            data.append(contentsOf: raw)
        }
    }
}

struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { max(0, bytes.count - offset) }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        let value = bytes[offset]
        offset += 1
        return value
    }

    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return value
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << (8 * UInt32(index))
        }
        offset += 4
        return value
    }

    mutating func u64() -> UInt64? {
        guard remaining >= 8 else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        offset += 8
        return value
    }

    mutating func f32() -> Float? {
        guard let bits = u32() else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func take(_ count: Int) -> Data? {
        guard count >= 0, remaining >= count else { return nil }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return Data(slice)
    }

    mutating func rest() -> Data {
        let slice = bytes[offset...]
        offset = bytes.count
        return Data(slice)
    }
}

// MARK: - Phone -> PC packets

enum PhonePacket {
    /// One controller's buttons and axes, appended to a pose packet. Twenty
    /// bytes each; see PC/PROTOCOL.md for the table.
    struct Controller {
        var slot: UInt8
        /// 0 left hand, 1 right hand, 2 gamepad.
        var role: UInt8
        var buttons: UInt16
        var leftStick: SIMD2<Int16>
        var rightStick: SIMD2<Int16>
        var leftTrigger: UInt8
        var rightTrigger: UInt8
        var battery: UInt8
    }

    /// One tracked hand, appended after the controller records. 192 bytes; the
    /// joints are 21 positions in millimetres in the head's own frame.
    struct Hand {
        /// 0 left, 1 right.
        var chirality: UInt8
        /// Bit 0 tracked, bit 1 depth came from the depth sensor.
        var flags: UInt8
        var confidence: UInt8
        var pinch: UInt16
        var gripPosition: SIMD3<Float>
        var gripRotation: simd_quatf
        var aimPosition: SIMD3<Float>
        var aimRotation: simd_quatf
        var joints: [SIMD3<Float>]
    }

    static func pose(_ snapshot: PoseSnapshot,
                     sequence: UInt32,
                     ipdMeters: Float,
                     screenWidth: UInt16,
                     screenHeight: UInt16,
                     controllers: [Controller] = [],
                     hands: [Hand] = []) -> Data {
        let forwarded = Array(controllers.prefix(4))
        let forwardedHands = Array(hands.prefix(2))

        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetPose)
        writer.u64(snapshot.timestampUs)
        writer.u32(sequence)
        writer.u8(snapshot.isSixDOF ? 1 : 0)
        writer.u8(UInt8(forwarded.count))
        writer.u8(UInt8(forwardedHands.count))
        writer.u8(0)             // reserved
        writer.f32(ipdMeters)
        writer.u16(screenWidth)
        writer.u16(screenHeight)
        writer.f32(snapshot.orientation.imag.x)
        writer.f32(snapshot.orientation.imag.y)
        writer.f32(snapshot.orientation.imag.z)
        writer.f32(snapshot.orientation.real)
        writer.f32(snapshot.position.x)
        writer.f32(snapshot.position.y)
        writer.f32(snapshot.position.z)
        writer.f32(snapshot.angularVelocity.x)
        writer.f32(snapshot.angularVelocity.y)
        writer.f32(snapshot.angularVelocity.z)

        for controller in forwarded {
            writer.u8(controller.slot)
            writer.u8(controller.role)
            writer.u16(controller.buttons)
            writer.u16(UInt16(bitPattern: controller.leftStick.x))
            writer.u16(UInt16(bitPattern: controller.leftStick.y))
            writer.u16(UInt16(bitPattern: controller.rightStick.x))
            writer.u16(UInt16(bitPattern: controller.rightStick.y))
            writer.u8(controller.leftTrigger)
            writer.u8(controller.rightTrigger)
            writer.u8(controller.battery)
            writer.u8(0)         // flags, reserved
            writer.u32(0)        // reserved
        }

        for hand in forwardedHands {
            writer.u8(hand.chirality)
            writer.u8(hand.flags)
            writer.u8(hand.confidence)
            writer.u8(0)         // reserved
            writer.u16(hand.pinch)
            writer.u16(0)        // reserved

            writer.f32(hand.gripPosition.x)
            writer.f32(hand.gripPosition.y)
            writer.f32(hand.gripPosition.z)
            writer.f32(hand.gripRotation.imag.x)
            writer.f32(hand.gripRotation.imag.y)
            writer.f32(hand.gripRotation.imag.z)
            writer.f32(hand.gripRotation.real)

            writer.f32(hand.aimPosition.x)
            writer.f32(hand.aimPosition.y)
            writer.f32(hand.aimPosition.z)
            writer.f32(hand.aimRotation.imag.x)
            writer.f32(hand.aimRotation.imag.y)
            writer.f32(hand.aimRotation.imag.z)
            writer.f32(hand.aimRotation.real)

            let joints = Array(hand.joints.prefix(21))
            for index in 0..<21 {
                let joint = index < joints.count ? joints[index] : SIMD3<Float>(0, 0, 0)
                writer.u16(UInt16(bitPattern: Int16(clamping: Int((joint.x * 1000).rounded()))))
                writer.u16(UInt16(bitPattern: Int16(clamping: Int((joint.y * 1000).rounded()))))
                writer.u16(UInt16(bitPattern: Int16(clamping: Int((joint.z * 1000).rounded()))))
            }

            writer.u16(0)
        }

        return writer.data
    }



    static func hello(name: String,
                      streamWidth: UInt16,
                      streamHeight: UInt16,
                      framesPerSecond: UInt16,
                      bitrateKbps: UInt16) -> Data {
        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetHello)
        writer.u64(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
        writer.u32(0)
        writer.u8(0)
        writer.u8(0)
        writer.u16(0)
        writer.f32(0)
        writer.u16(0)
        writer.u16(0)
        writer.u16(streamWidth)
        writer.u16(streamHeight)
        writer.u16(framesPerSecond)
        writer.u16(bitrateKbps)
        let nameBytes = Array(name.utf8.prefix(63))
        writer.u8(UInt8(nameBytes.count))
        writer.append(Data(nameBytes))
        return writer.data
    }

    static func bye() -> Data {
        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetBye)
        writer.u64(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
        writer.u32(0)
        writer.u8(0)
        writer.u8(0)
        writer.u16(0)
        writer.f32(0)
        writer.u16(0)
        writer.u16(0)
        return writer.data
    }

    static func ping(timestampUs: UInt64) -> Data {
        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetPing)
        writer.u64(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
        writer.u32(0)
        writer.u8(0)
        writer.u8(0)
        writer.u16(0)
        writer.f32(0)
        writer.u16(0)
        writer.u16(0)
        writer.u64(timestampUs)
        return writer.data
    }

    static func bitrate(kbps: UInt16) -> Data {
        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetBitrate)
        writer.u64(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
        writer.u32(0)
        writer.u8(0)
        writer.u8(0)
        writer.u16(0)
        writer.f32(0)
        writer.u16(0)
        writer.u16(0)
        writer.u16(kbps)
        writer.u16(0)
        return writer.data
    }

    struct Profile {
        var screenWidth: UInt16
        var screenHeight: UInt16
        var distortionK1: Float
        var distortionK2: Float
        var ipdMeters: Float
        var supersampling: Float
        var refreshRate: UInt16
        var fovCrop: Float
        var vignette: Float
    }

    static func profile(_ profile: Profile) -> Data {
        var writer = ByteWriter()
        writer.append(JVRProtocol.magicPose)
        writer.u16(JVRProtocol.version)
        writer.u16(JVRProtocol.packetProfile)
        writer.u64(UInt64(DispatchTime.now().uptimeNanoseconds / 1000))
        writer.u32(0)
        writer.u8(0)
        writer.u8(0)
        writer.u16(0)
        writer.f32(0)
        writer.u16(0)
        writer.u16(0)

        writer.u16(profile.screenWidth)
        writer.u16(profile.screenHeight)
        writer.f32(profile.distortionK1)
        writer.f32(profile.distortionK2)
        writer.f32(profile.ipdMeters)
        writer.f32(profile.supersampling)
        writer.u16(profile.refreshRate)
        writer.u16(0)
        writer.f32(profile.fovCrop)
        writer.f32(profile.vignette)
        return writer.data
    }
}

// MARK: - PC -> phone packets

struct ReplyPacket {
    var type: UInt16
    var timeUs: UInt64
    var serverName: String
    var encodeFPS: Int
    var bitrateKbps: Int

    static func decode(_ data: Data) -> ReplyPacket? {
        var reader = ByteReader(data)
        guard let header = reader.take(4), header == JVRProtocol.magicReply else { return nil }
        guard let _ = reader.u16(),
              let type = reader.u16(),
              let timeUs = reader.u64(),
              let nameLength = reader.u8() else { return nil }
        guard let nameData = reader.take(Int(nameLength)) else { return nil }
        let name = String(decoding: nameBytes(Array(nameData)), as: UTF8.self)
        let a = reader.u16() ?? 0
        let b = reader.u16() ?? 0
        return ReplyPacket(type: type,
                           timeUs: timeUs,
                           serverName: name,
                           encodeFPS: Int(a),
                           bitrateKbps: Int(b))
    }

    private static func nameBytes(_ raw: [UInt8]) -> [UInt8] { raw }
}

// MARK: - Video datagrams

struct VideoPacketHeader {
    var flags: UInt16
    var frameID: UInt64
    var fragmentIndex: Int
    var fragmentCount: Int
    var frameBytes: Int

    var isKeyframe: Bool { flags & 1 != 0 }

    static func parse(_ datagram: Data) -> (VideoPacketHeader, Data)? {
        var reader = ByteReader(datagram)
        guard let marker = reader.take(4), marker == JVRProtocol.magicVideo else { return nil }
        guard let _ = reader.u16(),
              let flags = reader.u16(),
              let frameID = reader.u64(),
              let fragmentIndex = reader.u16(),
              let fragmentCount = reader.u16(),
              let frameBytes = reader.u32() else { return nil }
        let payload = reader.rest()
        guard !payload.isEmpty else { return nil }
        let header = VideoPacketHeader(flags: flags,
                                       frameID: frameID,
                                       fragmentIndex: Int(fragmentIndex),
                                       fragmentCount: Int(fragmentCount),
                                       frameBytes: Int(frameBytes))
        return (header, payload)
    }
}
