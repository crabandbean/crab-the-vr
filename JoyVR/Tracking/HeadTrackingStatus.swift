//
//  HeadTrackingStatus.swift
//  JoyVR
//
//  What the tracking is doing right now, for the badge in the app and in VR.
//

import Foundation

struct HeadTrackingStatus: Equatable {
    enum Mode: String, Equatable {
        case off
        case threeDOF
        case sixDOF
    }

    var mode: Mode = .off
    var quality: Float = 0
    var note = "Not running"
    var isSupported = true
    /// True when 6DoF was wanted but the camera lost the room.
    var isFallback = false

    var qualityWord: String {
        switch quality {
        case 0.8...: return "Good"
        case 0.5...: return "Fair"
        case 0.01...: return "Weak"
        default: return "Off"
        }
    }

    var badgeTitle: String {
        switch mode {
        case .sixDOF: return "6DoF · \(qualityWord)"
        case .threeDOF: return isFallback ? "3DoF fallback" : "3DoF"
        case .off: return "Tracking idle"
        }
    }

    var isSixDOF: Bool { mode == .sixDOF }
}
