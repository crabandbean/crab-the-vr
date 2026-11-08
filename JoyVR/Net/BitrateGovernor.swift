//
//  BitrateGovernor.swift
//  JoyVR
//
//  Steps the requested bitrate down when video packets start dropping and
//  creeps back up once the link is clean again.
//

import Foundation

final class BitrateGovernor {
    private(set) var targetKbps: Int
    private(set) var currentKbps: Int

    private var quietSeconds = 0
    private let floorKbps = 8_000

    init(targetKbps: Int) {
        self.targetKbps = max(1_000, targetKbps)
        self.currentKbps = self.targetKbps
    }

    func reset(targetKbps: Int) {
        self.targetKbps = max(1_000, targetKbps)
        currentKbps = self.targetKbps
        quietSeconds = 0
    }

    /// One call a second. Returns the new bitrate when it changed.
    func update(dropped: Int, packets: Int) -> Int? {
        guard packets > 0 else { return nil }

        // A couple of lost datagrams a second is normal on Wi-Fi; a sustained
        // share of the stream is what stutters.
        let dropLimit = max(2, packets / 50)

        if dropped > dropLimit {
            quietSeconds = 0
            let reduced = max(floorKbps, currentKbps * 85 / 100)
            guard reduced < currentKbps else { return nil }
            currentKbps = reduced
            return currentKbps
        }

        if dropped == 0 {
            quietSeconds += 1
            if quietSeconds >= 5, currentKbps < targetKbps {
                quietSeconds = 0
                let raised = min(targetKbps, currentKbps + max(1_000, currentKbps / 10))
                guard raised > currentKbps else { return nil }
                currentKbps = raised
                return currentKbps
            }
        } else {
            quietSeconds = 0
        }

        return nil
    }
}
