//
//  StreamDiagnostics.swift
//  JoyVR
//
//  The live numbers on the Tune screen.
//

import Foundation

struct StreamDiagnostics: Equatable {
    var roundTripMs: Int?
    var poseLatencyMs: Int?
    var poseRate = 0
    var decodedFPS = 0
    var droppedPackets = 0
    var incomingKbps = 0
    var effectiveBitrateKbps = 0
    var targetBitrateKbps = 0
    var trackingMode = "—"

    var isAdapting: Bool {
        targetBitrateKbps > 0 && effectiveBitrateKbps < targetBitrateKbps
    }
}
