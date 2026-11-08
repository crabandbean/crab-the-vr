//
//  LinkSession.swift
//  JoyVR
//
//  One UDP connection to the PC companion. Poses and hello packets go out on
//  it; video datagrams and replies come back on it. Because the phone's packets
//  tell the PC where the phone is, the PC never needs to know its address in
//  advance.
//

import Foundation
import Network
import UIKit

final class LinkSession {
    enum LinkState: Equatable {
        case idle
        case connecting(host: String)
        case connected(host: String, name: String)
        case failed(String)
    }

    struct LatencySample {
        var poseMilliseconds: Int?
        var roundTripMs: Int?
    }

    private let queue = DispatchQueue(label: "com.joyvr.link")
    private var connection: NWConnection?
    private var poseTimer: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?

    private var sequence: UInt32 = 0
    private var sentPoses = 0
    private var lastReportedPoses = 0
    private var helloAttempts = 0
    private var gotAck = false
    private var lastPingTimestampUs: UInt64 = 0
    private var roundTripMs: Double?
    private var poseAgeTotalMs: Double = 0
    private var poseAgeSamples = 0
    private var paused = false

    private var host = ""
    private var port = JVRProtocol.streamPort
    private var requestedStream = (width: UInt16(2560), height: UInt16(1280), fps: UInt16(90), bitrate: UInt16(60000))

    // Wired up by the app model.
    var poseProvider: () -> PoseSnapshot = { PoseSnapshot() }
    var controllerProvider: () -> [PhonePacket.Controller] = { [] }
    var handProvider: () -> [PhonePacket.Hand] = { [] }
    var profileProvider: () -> PhonePacket.Profile? = { nil }
    var ipd: () -> Float = { 0.064 }
    var screenSize: () -> (UInt16, UInt16) = { (0, 0) }
    var onState: ((LinkState) -> Void)?
    var onVideo: ((Data) -> Void)?
    /// Poses sent per second, delivered on the main queue once a second.
    var onPoseRate: ((Int) -> Void)?
    /// Round-trip and pose latency, delivered once a second while connected.
    var onLatency: ((LatencySample) -> Void)?

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    private(set) var state: LinkState = .idle

    // MARK: Connecting

    func connect(host: String, port: UInt16, settings: StreamSettings) {
        stop()

        self.host = host
        self.port = port
        requestedStream = (UInt16(clamping: settings.quality.width),
                           UInt16(clamping: settings.quality.height),
                           UInt16(clamping: settings.refreshRate),
                           settings.bitrateKbps)

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            report(.failed("That port is not valid."))
            return
        }

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true

        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        self.connection = connection

        gotAck = false
        helloAttempts = 0
        sequence = 0
        sentPoses = 0
        lastReportedPoses = 0
        lastPingTimestampUs = 0
        roundTripMs = nil
        poseAgeTotalMs = 0
        poseAgeSamples = 0
        paused = false

        report(.connecting(host: host))

        connection.stateUpdateHandler = { [weak self] connectionState in
            guard let self else { return }
            switch connectionState {
            case .ready:
                self.beginStreaming()
            case .failed(let error):
                self.report(.failed(error.localizedDescription))
                self.stop()
            case .waiting(let error):
                self.report(.failed(error.localizedDescription))
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: connection)
    }

    func disconnect() {
        stop()
        report(.idle)
    }

    private func stop() {
        poseTimer?.cancel()
        poseTimer = nil
        statsTimer?.cancel()
        statsTimer = nil
        pingTimer?.cancel()
        pingTimer = nil
        roundTripMs = nil
        lastPingTimestampUs = 0
        poseAgeTotalMs = 0
        poseAgeSamples = 0

        if let connection {
            connection.send(content: PhonePacket.bye(), completion: .idempotent)
        }
        connection?.cancel()
        connection = nil
        gotAck = false
    }

    /// Changes the bitrate the PC encodes at, without dropping the link.
    func setBitrate(kbps: Int) {
        let clamped = UInt16(clamping: min(max(kbps, 500), 65_535))
        queue.async { [weak self] in
            guard let self else { return }
            guard self.requestedStream.bitrate != clamped else { return }
            self.requestedStream.bitrate = clamped
            guard let connection = self.connection else { return }
            connection.send(content: PhonePacket.bitrate(kbps: clamped), completion: .idempotent)
        }
    }

    /// Sends the lens and comfort numbers so the PC renders the same projection.
    func sendProfile(_ profile: PhonePacket.Profile) {
        queue.async { [weak self] in
            self?.sendProfilePacket(profile)
        }
    }

    private func sendProfilePacket(_ profile: PhonePacket.Profile) {
        guard let connection else { return }
        connection.send(content: PhonePacket.profile(profile), completion: .idempotent)
    }

    /// While paused the phone stops sending poses, so the view in the box holds still.
    func setPaused(_ paused: Bool) {
        queue.async { [weak self] in
            self?.paused = paused
        }
    }

    // MARK: Receiving

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handle(data)
            }
            if error == nil, self.connection === connection {
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ data: Data) {
        if data.starts(with: JVRProtocol.magicVideo) {
            onVideo?(data)
            return
        }
        if data.starts(with: JVRProtocol.magicDiscoverReply) {
            return
        }
        if let reply = ReplyPacket.decode(data) {
            switch reply.type {
            case JVRProtocol.replyAck:
                gotAck = true
                report(.connected(host: host, name: reply.serverName))
                if let profile = profileProvider() {
                    sendProfilePacket(profile)
                }
            case JVRProtocol.replyPong:
                let now = PoseMath.nowMicroseconds()
                if reply.timeUs == lastPingTimestampUs, now > reply.timeUs {
                    let measured = Double(now - reply.timeUs) / 1000
                    roundTripMs = roundTripMs.map { $0 * 0.7 + measured * 0.3 } ?? measured
                }
            default:
                break
            }
        }
    }

    // MARK: Sending

    private func beginStreaming() {
        sendHello()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.025, repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        poseTimer = timer

        let stats = DispatchSource.makeTimerSource(queue: queue)
        stats.schedule(deadline: .now() + 1, repeating: 1)
        stats.setEventHandler { [weak self] in
            guard let self else { return }
            let rate = self.sentPoses - self.lastReportedPoses
            self.lastReportedPoses = self.sentPoses

            let averageAge = self.poseAgeSamples > 0
                ? self.poseAgeTotalMs / Double(self.poseAgeSamples)
                : 0
            let hasPose = self.poseAgeSamples > 0
            let rtt = self.roundTripMs
            let poseMs = hasPose
                ? Int((averageAge + (rtt ?? 0) / 2).rounded())
                : nil
            let rttMs = rtt.map { Int($0.rounded()) }
            self.poseAgeTotalMs = 0
            self.poseAgeSamples = 0

            DispatchQueue.main.async {
                self.onPoseRate?(rate)
                self.onLatency?(LatencySample(poseMilliseconds: poseMs, roundTripMs: rttMs))
            }
        }
        stats.resume()
        statsTimer = stats

        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 1, repeating: 2)
        ping.setEventHandler { [weak self] in self?.sendPing() }
        ping.resume()
        pingTimer = ping
    }

    private func sendPing() {
        guard let connection, gotAck else { return }
        let timestamp = PoseMath.nowMicroseconds()
        lastPingTimestampUs = timestamp
        connection.send(content: PhonePacket.ping(timestampUs: timestamp), completion: .idempotent)
    }

    private func sendHello() {
        guard let connection else { return }
        let name = UIDevice.current.name
        let packet = PhonePacket.hello(name: name,
                                       streamWidth: requestedStream.width,
                                       streamHeight: requestedStream.height,
                                       framesPerSecond: requestedStream.fps,
                                       bitrateKbps: requestedStream.bitrate)
        connection.send(content: packet, completion: .idempotent)
    }

    private func tick() {
        guard let connection else { return }
        guard !paused else { return }

        sequence &+= 1
        let snapshot = poseProvider()
        let (width, height) = screenSize()
        let packet = PhonePacket.pose(snapshot,
                                      sequence: sequence,
                                      ipdMeters: ipd(),
                                      screenWidth: width,
                                      screenHeight: height,
                                      controllers: controllerProvider(),
                                      hands: handProvider())
        connection.send(content: packet, completion: .idempotent)
        sentPoses += 1

        let ageMs = Double(PoseMath.nowMicroseconds() &- snapshot.timestampUs) / 1000
        if ageMs >= 0, ageMs < 500 {
            poseAgeTotalMs += ageMs
            poseAgeSamples += 1
        }

        // Keep asking until the PC answers, then stop.
        guard !gotAck else { return }
        helloAttempts += 1
        if helloAttempts % 30 == 0 {
            if helloAttempts > 300 {
                report(.failed("The PC did not answer. Is the Crab the VR PC app running on the same Wi-Fi?"))
                stop()
            } else {
                sendHello()
            }
        }
    }

    private func report(_ state: LinkState) {
        self.state = state
        DispatchQueue.main.async { [weak self] in
            self?.onState?(state)
        }
    }
}
