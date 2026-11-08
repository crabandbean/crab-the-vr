//
//  VRProfile.swift
//  JoyVR
//
//  One named headset setup: the lens numbers plus the comfort settings for the
//  game it is meant for.
//

import Foundation

struct VRProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Optional game this comfort setup belongs to.
    var game: String = ""

    // Lens and screen.
    var quality: StreamSettings.Quality = .high
    var distortionK1: Double = 0.20
    var distortionK2: Double = 0.04
    var chromaticAberration: Double = 0.0
    var ipdMillimeters: Double = 64

    // Comfort.
    var supersampling: Double = 1.0
    var refreshRate: Int = 90
    var fovCrop: Double = 0.0
    var vignette: Double = 0.0

    init(id: UUID = UUID(),
         name: String,
         game: String = "",
         settings: StreamSettings) {
        self.id = id
        self.name = name
        self.game = game
        quality = settings.quality
        distortionK1 = settings.distortionK1
        distortionK2 = settings.distortionK2
        chromaticAberration = settings.chromaticAberration
        ipdMillimeters = settings.ipdMillimeters
        supersampling = settings.supersampling
        refreshRate = settings.refreshRate
        fovCrop = settings.fovCrop
        vignette = settings.vignette
    }

    func apply(to settings: inout StreamSettings) {
        settings.quality = quality
        settings.distortionK1 = distortionK1
        settings.distortionK2 = distortionK2
        settings.chromaticAberration = chromaticAberration
        settings.ipdMillimeters = ipdMillimeters
        settings.supersampling = supersampling
        settings.refreshRate = refreshRate
        settings.fovCrop = fovCrop
        settings.vignette = vignette
    }

    var summary: String {
        "IPD \(Int(ipdMillimeters.rounded())) mm · \(refreshRate) Hz · k1 \(String(format: "%.2f", distortionK1))"
    }
}
