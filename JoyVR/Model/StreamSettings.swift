//
//  StreamSettings.swift
//  JoyVR
//
//  Everything the phone asks the PC to do, and the values the renderer needs
//  to make the picture fit inside a phone VR box.
//

import Foundation

struct StreamSettings: Codable, Equatable {
    enum Quality: String, Codable, CaseIterable, Identifiable {
        case low
        case medium
        case high
        case ultra

        var id: String { rawValue }

        var title: String {
            switch self {
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            case .ultra: return "Ultra"
            }
        }

        /// Total side-by-side resolution sent by the PC (both eyes together).
        var width: Int {
            switch self {
            case .low: return 1600
            case .medium: return 2048
            case .high: return 2560
            case .ultra: return 3200
            }
        }

        var height: Int {
            switch self {
            case .low: return 800
            case .medium: return 1024
            case .high: return 1280
            case .ultra: return 1600
            }
        }

        var detail: String { "\(width) × \(height)" }

        /// Resolution of one eye, which is what the renderer lays out on screen.
        var eyeWidth: Int { width / 2 }
    }

    var quality: Quality = .high
    var bitrateMbps: Int = 60
    var refreshRate: Int = 90
    var showTestPattern: Bool = false

    // Picture tuning, applied live by the renderer.
    var distortionK1: Double = 0.20
    var distortionK2: Double = 0.04
    var chromaticAberration: Double = 0.0
    var ipdMillimeters: Double = 64
    var brightness: Double = 1.0
    var saturation: Double = 1.0

    // Comfort settings, saved with a profile and sent to the PC.
    var supersampling: Double = 1.0
    var fovCrop: Double = 0.0
    var vignette: Double = 0.0

    /// Position as well as rotation for the head: ARKit watches the room and the
    /// gyro fills in between. With it off the pose is rotation only.
    var sixDOFEnabled: Bool = true
    /// 0 follows the head as closely as the camera allows, 1 smooths out the
    /// small shakes of holding the box.
    var sixDOFStability: Double = 0.35
    /// Camera hand tracking: up to two hands go to the PC as tracked controllers.
    var handTrackingEnabled: Bool = false
    /// Lets a paired controller walk and turn the view, so the phone in the box
    /// never has to be touched.
    var controllerLocomotion: Bool = true
    /// Metres per second with the left stick fully pushed.
    var walkSpeed: Double = 1.2
    /// Degrees per second with the right stick fully pushed.
    var turnSpeed: Double = 120

    init() {}

    var bitrateKbps: UInt16 {
        UInt16(clamping: bitrateMbps * 1000)
    }

    static let refreshChoices = [60, 72, 90, 120]

    var pictureTuning: PictureTuning {
        PictureTuning(distortionK1: Float(distortionK1),
                      distortionK2: Float(distortionK2),
                      chromaticAberration: Float(chromaticAberration),
                      brightness: Float(brightness),
                      saturation: Float(saturation),
                      vignette: Float(vignette))
    }

    // Settings saved by an older build do not have the tracking keys yet, so
    // every field falls back to its default instead of throwing away the lot.
    private enum CodingKeys: String, CodingKey {
        case quality
        case bitrateMbps
        case refreshRate
        case showTestPattern
        case distortionK1
        case distortionK2
        case chromaticAberration
        case ipdMillimeters
        case brightness
        case saturation
        case supersampling
        case fovCrop
        case vignette
        case sixDOFEnabled
        case sixDOFStability
        case handTrackingEnabled
        case controllerLocomotion
        case walkSpeed
        case turnSpeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = StreamSettings()

        quality = try container.decodeIfPresent(Quality.self, forKey: .quality) ?? fallback.quality
        bitrateMbps = try container.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? fallback.bitrateMbps
        refreshRate = try container.decodeIfPresent(Int.self, forKey: .refreshRate) ?? fallback.refreshRate
        showTestPattern = try container.decodeIfPresent(Bool.self, forKey: .showTestPattern) ?? fallback.showTestPattern
        distortionK1 = try container.decodeIfPresent(Double.self, forKey: .distortionK1) ?? fallback.distortionK1
        distortionK2 = try container.decodeIfPresent(Double.self, forKey: .distortionK2) ?? fallback.distortionK2
        chromaticAberration = try container.decodeIfPresent(Double.self, forKey: .chromaticAberration) ?? fallback.chromaticAberration
        ipdMillimeters = try container.decodeIfPresent(Double.self, forKey: .ipdMillimeters) ?? fallback.ipdMillimeters
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? fallback.brightness
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? fallback.saturation
        supersampling = try container.decodeIfPresent(Double.self, forKey: .supersampling) ?? fallback.supersampling
        fovCrop = try container.decodeIfPresent(Double.self, forKey: .fovCrop) ?? fallback.fovCrop
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? fallback.vignette
        sixDOFEnabled = try container.decodeIfPresent(Bool.self, forKey: .sixDOFEnabled) ?? fallback.sixDOFEnabled
        sixDOFStability = try container.decodeIfPresent(Double.self, forKey: .sixDOFStability) ?? fallback.sixDOFStability
        handTrackingEnabled = try container.decodeIfPresent(Bool.self, forKey: .handTrackingEnabled) ?? fallback.handTrackingEnabled
        controllerLocomotion = try container.decodeIfPresent(Bool.self, forKey: .controllerLocomotion) ?? fallback.controllerLocomotion
        walkSpeed = try container.decodeIfPresent(Double.self, forKey: .walkSpeed) ?? fallback.walkSpeed
        turnSpeed = try container.decodeIfPresent(Double.self, forKey: .turnSpeed) ?? fallback.turnSpeed
    }
}

/// The picture settings the renderer applies every frame.
struct PictureTuning: Equatable {
    var distortionK1: Float = 0.20
    var distortionK2: Float = 0.04
    var chromaticAberration: Float = 0.0
    var brightness: Float = 1.0
    var saturation: Float = 1.0
    var vignette: Float = 0.0
}
