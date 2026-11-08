//
//  Discovery.swift
//  JoyVR
//
//  Finds the PC companion on the local network with a UDP broadcast, and reads
//  the name it answers with.
//

import Foundation
import UIKit

final class Discovery {
    struct FoundPC: Identifiable, Hashable {
        let address: String
        var name: String
        var port: UInt16

        var id: String { address }
    }

    /// Blocking call: run it off the main thread.
    static func scan(timeout: TimeInterval = 2.0) -> [FoundPC] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var wait = timeval(tv_sec: 0, tv_usec: 150_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = JVRProtocol.discoveryPort.bigEndian
        destination.sin_addr.s_addr = inet_addr("255.255.255.255")

        var query = JVRProtocol.magicDiscover
        query.append(contentsOf: [UInt8(JVRProtocol.version & 0xFF),
                                  UInt8((JVRProtocol.version >> 8) & 0xFF)])

        let deviceName = UIDevice.current.name
        var nameBytes = Array(deviceName.utf8.prefix(63))
        query.append(UInt8(nameBytes.count))
        query.append(contentsOf: nameBytes)
        nameBytes.removeAll()

        _ = query.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(descriptor,
                           buffer.baseAddress,
                           buffer.count,
                           0,
                           sockaddrPointer,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [String: FoundPC] = [:]
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(descriptor, &buffer, buffer.count, 0, sockaddrPointer, &sourceLength)
                }
            }
            guard received > 0 else { continue }

            let datagram = Data(buffer[0..<received])
            guard datagram.starts(with: JVRProtocol.magicDiscoverReply) else { continue }
            guard let reply = parseReply(datagram) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            inet_ntop(AF_INET, &source.sin_addr, &host, socklen_t(host.count))
            let address = String(cString: host)
            guard address != "0.0.0.0", !address.isEmpty else { continue }

            found[address] = FoundPC(address: address, name: reply.name, port: reply.port)
        }

        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parseReply(_ datagram: Data) -> (name: String, port: UInt16)? {
        var reader = ByteReader(datagram)
        guard let marker = reader.take(4), marker == JVRProtocol.magicDiscoverReply else { return nil }
        guard let _ = reader.u16(),
              let port = reader.u16(),
              let _ = reader.u8(),
              let nameLength = reader.u8(),
              let nameData = reader.take(Int(nameLength)) else { return nil }
        let name = String(decoding: [UInt8](nameData), as: UTF8.self)
        return (name.isEmpty ? "PC" : name, port == 0 ? JVRProtocol.streamPort : port)
    }
}
