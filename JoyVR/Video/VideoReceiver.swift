//
//  VideoReceiver.swift
//  JoyVR
//
//  Reassembles the fragments of one H.264 frame that the PC split across
//  datagrams. Fragments of newer frames always win over older ones, so a single
//  lost datagram costs one frame instead of a stutter.
//

import Foundation

final class VideoReceiver {
    struct Stats {
        var packets = 0
        var bytes = 0
        var frames = 0
        var dropped = 0
    }

    private struct Assembly {
        var fragments: [Int: Data] = [:]
        var fragmentCount: Int
        var frameBytes: Int
        var received = 0
        var bytes = 0
        var isKeyframe: Bool
    }

    private var pending: [UInt64: Assembly] = [:]
    private var newestCompleted: UInt64 = 0
    private var stats = Stats()
    private let statsLock = NSLock()

    /// Called with one complete access unit in Annex-B form.
    var onAccessUnit: ((Data, Bool) -> Void)?

    func reset() {
        pending.removeAll()
        newestCompleted = 0
        statsLock.lock()
        stats = Stats()
        statsLock.unlock()
    }

    func statsSnapshot() -> Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return stats
    }

    private func record(packets: Int = 0, bytes: Int = 0, frames: Int = 0, dropped: Int = 0) {
        statsLock.lock()
        stats.packets += packets
        stats.bytes += bytes
        stats.frames += frames
        stats.dropped += dropped
        statsLock.unlock()
    }

    func consume(_ datagram: Data) {
        guard let (header, payload) = VideoPacketHeader.parse(datagram) else { return }
        guard header.fragmentCount > 0 else { return }
        guard header.fragmentIndex < header.fragmentCount else { return }

        record(packets: 1, bytes: datagram.count)

        guard header.frameID + 3 > newestCompleted else {
            record(dropped: 1)
            return
        }

        var assembly = pending[header.frameID] ?? Assembly(fragmentCount: header.fragmentCount,
                                                           frameBytes: header.frameBytes,
                                                           isKeyframe: header.isKeyframe)

        if assembly.fragments[header.fragmentIndex] == nil {
            assembly.fragments[header.fragmentIndex] = payload
            assembly.received += 1
            assembly.bytes += payload.count
        }
        pending[header.frameID] = assembly

        if assembly.received >= header.fragmentCount || assembly.bytes >= header.frameBytes {
            finish(header.frameID)
        }

        if pending.count > 12, let oldest = pending.keys.min() {
            pending.removeValue(forKey: oldest)
            record(dropped: 1)
        }
    }

    private func finish(_ frameID: UInt64) {
        guard let assembly = pending.removeValue(forKey: frameID) else { return }

        var data = Data(capacity: max(assembly.frameBytes, 0))
        for index in 0..<assembly.fragmentCount {
            guard let fragment = assembly.fragments[index] else {
                record(dropped: 1)
                return
            }
            data.append(fragment)
        }

        guard !data.isEmpty else { return }

        newestCompleted = max(newestCompleted, frameID)
        record(frames: 1)
        onAccessUnit?(data, assembly.isKeyframe)
    }
}
