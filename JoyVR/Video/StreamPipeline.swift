//
//  StreamPipeline.swift
//  JoyVR
//
//  Glue between the socket, the receiver and the decoder. The renderer asks it
//  for the most recent decoded frame; the diagnostics panel asks it for rates.
//

import CoreVideo
import Foundation

final class StreamPipeline {
    struct Metrics {
        var decodedFPS = 0
        var incomingKbps = 0
        var packetsPerSecond = 0
        var droppedPerSecond = 0
        var droppedTotal = 0
    }

    private let receiver = VideoReceiver()
    private let decoder = H264Decoder()
    private let lock = NSLock()

    private var latest: CVPixelBuffer?
    private var decodedFrames = 0

    private var lastSampleTime: TimeInterval = 0
    private var lastDecoded = 0
    private var lastPackets = 0
    private var lastBytes = 0
    private var lastDropped = 0

    init() {
        decoder.onFrame = { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            self.latest = buffer
            self.decodedFrames += 1
            self.lock.unlock()
        }
        receiver.onAccessUnit = { [weak self] data, _ in
            self?.decoder.decode(accessUnit: data)
        }
    }

    func handleVideoPacket(_ datagram: Data) {
        receiver.consume(datagram)
    }

    func currentBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Deltas since the previous call, meant to be called about once a second.
    func sampleMetrics() -> Metrics {
        let now = Date().timeIntervalSinceReferenceDate
        let stats = receiver.statsSnapshot()

        lock.lock()
        let decoded = decodedFrames
        lock.unlock()

        defer {
            lastSampleTime = now
            lastDecoded = decoded
            lastPackets = stats.packets
            lastBytes = stats.bytes
            lastDropped = stats.dropped
        }

        guard lastSampleTime > 0 else {
            return Metrics(decodedFPS: 0,
                           incomingKbps: 0,
                           packetsPerSecond: 0,
                           droppedPerSecond: 0,
                           droppedTotal: stats.dropped)
        }

        let elapsed = max(0.2, now - lastSampleTime)
        let frames = max(0, decoded - lastDecoded)
        let packets = max(0, stats.packets - lastPackets)
        let bytes = max(0, stats.bytes - lastBytes)
        let dropped = max(0, stats.dropped - lastDropped)

        return Metrics(decodedFPS: Int((Double(frames) / elapsed).rounded()),
                       incomingKbps: Int((Double(bytes) * 8 / 1000 / elapsed).rounded()),
                       packetsPerSecond: Int((Double(packets) / elapsed).rounded()),
                       droppedPerSecond: dropped,
                       droppedTotal: stats.dropped)
    }

    func reset() {
        lock.lock()
        latest = nil
        decodedFrames = 0
        lastSampleTime = 0
        lastDecoded = 0
        lock.unlock()
        receiver.reset()
        decoder.reset()

        let stats = receiver.statsSnapshot()
        lastPackets = stats.packets
        lastBytes = stats.bytes
        lastDropped = stats.dropped
    }
}
