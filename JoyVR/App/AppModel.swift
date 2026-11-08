//
//  AppModel.swift
//  JoyVR
//
//  Owns the link, the head tracker, the controller and the settings, and keeps
//  them saved. It also puts the head pose and the controller's stick movement
//  together into the pose that goes to the PC.
//

import Foundation
import QuartzCore
import SwiftUI
import UIKit
import simd

final class AppModel: ObservableObject {
    enum Tab: Hashable {
        case link
        case controllers
        case tune
        case pc
        case settings
    }

    @Published var settings: StreamSettings {
        didSet {
            saveSettings()
            applyTrackingSettings()
            if oldValue.bitrateMbps != settings.bitrateMbps {
                applyBitrateTarget()
            }
            if oldValue.ipdMillimeters != settings.ipdMillimeters
                || oldValue.supersampling != settings.supersampling
                || oldValue.fovCrop != settings.fovCrop
                || oldValue.vignette != settings.vignette
                || oldValue.refreshRate != settings.refreshRate
                || oldValue.quality != settings.quality {
                sendCurrentProfile()
            }
        }
    }
    @Published var selectedTab: Tab = .link

    @Published var linkState: LinkSession.LinkState = .idle
    @Published var discovered: [Discovery.FoundPC] = []
    @Published var isScanning = false
    @Published var isInVR = false
    @Published var vrOverlayVisible = true
    @Published var poseRate = 0
    @Published var trackingStatus = HeadTrackingStatus()
    @Published private(set) var diagnostics = StreamDiagnostics()
    @Published private(set) var profiles: [VRProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published var isVRPaused = false
    @Published var errorText: String?

    @Published private(set) var rememberedHost: String?
    @Published private(set) var rememberedName: String?

    let pipeline = StreamPipeline()
    let headTracker = HeadTracker()
    let gamepad = GamepadTracker()
    let hands = HandTracker()

    private var session: LinkSession?
    private let displaySize: (UInt16, UInt16)

    private var diagnosticsTimer: Timer?
    private var bitrateGovernor: BitrateGovernor?
    private var latencySample: LinkSession.LatencySample?

    /// View movement from the controller, integrated as poses go out.
    private var lastPoseTime: CFTimeInterval = 0
    private var turnOffset: Float = 0
    private var locomotion = SIMD3<Float>(0, 0, 0)

    private enum StorageKey {
        static let settings = "joyvr.settings"
        static let lastHost = "joyvr.lastHost"
        static let lastName = "joyvr.lastName"
        static let profiles = "joyvr.profiles"
        static let activeProfile = "joyvr.activeProfile"
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: StorageKey.settings),
           let decoded = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            settings = decoded
        } else {
            settings = StreamSettings()
        }

        rememberedHost = UserDefaults.standard.string(forKey: StorageKey.lastHost)
        rememberedName = UserDefaults.standard.string(forKey: StorageKey.lastName)

        if let data = UserDefaults.standard.data(forKey: StorageKey.profiles),
           let saved = try? JSONDecoder().decode([VRProfile].self, from: data) {
            profiles = saved
        }
        if let idString = UserDefaults.standard.string(forKey: StorageKey.activeProfile),
           let id = UUID(uuidString: idString) {
            activeProfileID = id
        }

        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let long = Int(max(bounds.width, bounds.height) * scale)
        let short = Int(min(bounds.width, bounds.height) * scale)
        displaySize = (UInt16(clamping: long), UInt16(clamping: short))

        gamepad.onAction = { [weak self] action in
            self?.handle(action)
        }
        headTracker.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.trackingStatus = status
            }
        }
        hands.attach(to: headTracker.visual)
        trackingStatus = headTracker.status
        applyTrackingSettings()
    }

    // MARK: Derived state

    var isConnected: Bool {
        if case .connected = linkState { return true }
        return false
    }

    var serverName: String {
        if case .connected(_, let name) = linkState { return name }
        return rememberedName ?? ""
    }

    var headTrackingAvailable: Bool { headTracker.isAvailable }

    var isControllerMoving: Bool {
        settings.controllerLocomotion && gamepad.primaryPad != nil
    }

    // MARK: Finding a PC

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        discovered = []
        errorText = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Discovery.scan()
            DispatchQueue.main.async {
                self?.discovered = found
                self?.isScanning = false
            }
        }
    }

    // MARK: Linking

    func connect(host: String, port: UInt16 = JVRProtocol.streamPort, name: String? = nil) {
        disconnect()

        let session = LinkSession()
        session.poseProvider = { [weak self] in
            self?.composedPose() ?? PoseSnapshot()
        }
        session.controllerProvider = { [weak self] in
            self?.gamepad.forwardedControllers ?? []
        }
        session.handProvider = { [weak self] in
            self?.hands.forwardedHands ?? []
        }
        session.profileProvider = { [weak self] in
            self?.currentProfilePacket
        }
        session.ipd = { [weak self] in
            Float((self?.settings.ipdMillimeters ?? 64) / 1000)
        }
        session.screenSize = { [weak self] in
            self?.displaySize ?? (0, 0)
        }

        session.onState = { [weak self] state in
            guard let self else { return }
            self.linkState = state
            switch state {
            case .connected(_, let serverName):
                self.errorText = nil
                self.headTracker.start()
                self.remember(host: host, name: serverName.isEmpty ? (name ?? host) : serverName)
            case .failed(let message):
                self.errorText = message
            default:
                break
            }
        }

        session.onVideo = { [weak self] data in
            self?.pipeline.handleVideoPacket(data)
        }
        session.onPoseRate = { [weak self] rate in
            self?.poseRate = rate
        }
        session.onLatency = { [weak self] sample in
            self?.latencySample = sample
        }

        resetPoseMotion()
        self.session = session
        bitrateGovernor = BitrateGovernor(targetKbps: Int(settings.bitrateKbps))
        latencySample = nil
        startDiagnosticsTimer()
        session.setPaused(false)
        session.connect(host: host, port: port, settings: settings)
    }

    func disconnect() {
        session?.disconnect()
        session = nil
        pipeline.reset()
        headTracker.stop()
        resetPoseMotion()
        stopDiagnosticsTimer()
        bitrateGovernor = nil
        latencySample = nil
        diagnostics = StreamDiagnostics()
        isVRPaused = false
        linkState = .idle
    }

    func forgetSavedPC() {
        rememberedHost = nil
        rememberedName = nil
        UserDefaults.standard.removeObject(forKey: StorageKey.lastHost)
        UserDefaults.standard.removeObject(forKey: StorageKey.lastName)
    }

    private func remember(host: String, name: String) {
        rememberedHost = host
        rememberedName = name
        UserDefaults.standard.set(host, forKey: StorageKey.lastHost)
        UserDefaults.standard.set(name, forKey: StorageKey.lastName)
    }

    // MARK: VR

    func enterVR() {
        pipeline.reset()
        if headTracker.isAvailable {
            headTracker.start()
        }
        resetPoseMotion()
        vrOverlayVisible = true
        setVRPaused(false)
        errorText = nil
        isInVR = true
    }

    func exitVR() {
        setVRPaused(false)
        isInVR = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func recenter() {
        headTracker.recenter()
        resetPoseMotion()
    }

    // MARK: Tracking setup

    /// Lets the setup screen use the camera before a PC is linked or VR started.
    func beginTrackingSetup() {
        if !settings.sixDOFEnabled {
            settings.sixDOFEnabled = true
        }
        if headTracker.isAvailable {
            headTracker.start()
        }
    }

    func endTrackingSetup() {
        if !isConnected && !isInVR {
            headTracker.stop()
        }
    }

    func calibrateEyeLevel() {
        headTracker.calibrateEyeLevel()
    }

    func calibrateForward() {
        headTracker.calibrateForward()
        resetPoseMotion()
    }

    func toggleVROverlay() {
        vrOverlayVisible.toggle()
    }

    // MARK: Controller

    /// The buttons on a paired pad drive the app, so a phone inside a box never
    /// has to be touched: A enters VR (and shows the overlay once inside), B
    /// leaves it, the shoulders snap turn, Y recenters.
    private func handle(_ action: GamepadTracker.Action) {
        switch action {
        case .recenter:
            recenter()
        case .enterVR:
            if isInVR {
                toggleVROverlay()
            } else {
                enterVR()
            }
        case .exitVR:
            if isInVR {
                exitVR()
            }
        case .toggleOverlay:
            if isInVR {
                toggleVROverlay()
            }
        case .snapTurnLeft:
            turnOffset += .pi / 6
        case .snapTurnRight:
            turnOffset -= .pi / 6
        }
    }

    // MARK: Pose

    /// Head rotation and position from the phone, then the controller's sticks
    /// on top: the right stick turns the view, the left one walks it.
    private func composedPose() -> PoseSnapshot {
        var pose = headTracker.current

        let now = CACurrentMediaTime()
        let dt = lastPoseTime == 0 ? 0 : min(max(now - lastPoseTime, 0), 0.1)
        lastPoseTime = now

        guard settings.controllerLocomotion, isInVR else {
            return pose
        }

        let sticks = gamepad.currentSticks

        if abs(sticks.turn) > 0.15 {
            let rate = Float(settings.turnSpeed) * .pi / 180
            turnOffset -= sticks.turn * rate * Float(dt)
        }

        if turnOffset != 0 {
            let rotation = PoseMath.yawRotation(turnOffset)
            pose.orientation = PoseMath.normalized(rotation * pose.orientation)
            pose.angularVelocity = rotation.act(pose.angularVelocity)
        }

        var move = sticks.move
        if abs(move.x) < 0.15 { move.x = 0 }
        if abs(move.y) < 0.15 { move.y = 0 }

        if move.x != 0 || move.y != 0 {
            let heading = PoseMath.yaw(of: pose.orientation)
            let forward = SIMD3<Float>(-sin(heading), 0, -cos(heading))
            let right = SIMD3<Float>(cos(heading), 0, -sin(heading))
            let direction = forward * move.y + right * move.x
            locomotion += direction * Float(settings.walkSpeed) * Float(dt)
        }

        pose.position += locomotion
        pose.isSixDOF = true

        return pose
    }

    private func resetPoseMotion() {
        lastPoseTime = 0
        turnOffset = 0
        locomotion = SIMD3<Float>(0, 0, 0)
    }

    // MARK: Diagnostics

    var pictureTuning: PictureTuning { settings.pictureTuning }

    // MARK: Profiles

    var activeProfile: VRProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    var currentProfilePacket: PhonePacket.Profile {
        PhonePacket.Profile(screenWidth: UInt16(clamping: settings.quality.width),
                            screenHeight: UInt16(clamping: settings.quality.height),
                            distortionK1: Float(settings.distortionK1),
                            distortionK2: Float(settings.distortionK2),
                            ipdMeters: Float(settings.ipdMillimeters / 1000),
                            supersampling: Float(settings.supersampling),
                            refreshRate: UInt16(clamping: settings.refreshRate),
                            fovCrop: Float(settings.fovCrop),
                            vignette: Float(settings.vignette))
    }

    @discardableResult
    func saveProfile(name: String, game: String) -> VRProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let profile = VRProfile(name: trimmedName,
                                game: game.trimmingCharacters(in: .whitespacesAndNewlines),
                                settings: settings)
        profiles.append(profile)
        activeProfileID = profile.id
        persistProfiles()
        sendCurrentProfile()
        return profile
    }

    func applyProfile(_ profile: VRProfile) {
        var updated = settings
        profile.apply(to: &updated)
        settings = updated
        activeProfileID = profile.id
        persistProfiles()
    }

    func updateActiveProfile() {
        guard let id = activeProfileID,
              let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        let existing = profiles[index]
        profiles[index] = VRProfile(id: existing.id,
                                    name: existing.name,
                                    game: existing.game,
                                    settings: settings)
        persistProfiles()
    }

    func deleteProfile(_ profile: VRProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = nil
        }
        persistProfiles()
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: StorageKey.profiles)
        }
        if let activeProfileID {
            UserDefaults.standard.set(activeProfileID.uuidString, forKey: StorageKey.activeProfile)
        } else {
            UserDefaults.standard.removeObject(forKey: StorageKey.activeProfile)
        }
    }

    private func sendCurrentProfile() {
        session?.sendProfile(currentProfilePacket)
    }

    // MARK: Pause

    /// Long-press inside the box: poses stop being sent, so the view holds still.
    func toggleVRPause() {
        setVRPaused(!isVRPaused)
    }

    func setVRPaused(_ paused: Bool) {
        guard isVRPaused != paused else { return }
        isVRPaused = paused
        session?.setPaused(paused)
        if paused {
            vrOverlayVisible = false
        }
    }

    // MARK: Diagnostics

    private func startDiagnosticsTimer() {
        stopDiagnosticsTimer()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tickDiagnostics()
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticsTimer = timer
    }

    private func stopDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
    }

    private func applyBitrateTarget() {
        guard let session, isConnected, let governor = bitrateGovernor else { return }
        governor.reset(targetKbps: Int(settings.bitrateKbps))
        session.setBitrate(kbps: governor.currentKbps)
    }

    private func tickDiagnostics() {
        guard let session, isConnected else { return }

        let metrics = pipeline.sampleMetrics()
        if let governor = bitrateGovernor,
           let newRate = governor.update(dropped: metrics.droppedPerSecond,
                                         packets: metrics.packetsPerSecond) {
            session.setBitrate(kbps: newRate)
        }

        var updated = StreamDiagnostics()
        updated.roundTripMs = latencySample?.roundTripMs
        updated.poseLatencyMs = latencySample?.poseMilliseconds
        updated.poseRate = poseRate
        updated.decodedFPS = metrics.decodedFPS
        updated.droppedPackets = metrics.droppedTotal
        updated.incomingKbps = metrics.incomingKbps
        updated.effectiveBitrateKbps = bitrateGovernor?.currentKbps ?? Int(settings.bitrateKbps)
        updated.targetBitrateKbps = bitrateGovernor?.targetKbps ?? Int(settings.bitrateKbps)
        updated.trackingMode = trackingStatus.badgeTitle
        diagnostics = updated
    }

    // MARK: Saving

    private func applyTrackingSettings() {
        headTracker.isSixDOFEnabled = settings.sixDOFEnabled
        headTracker.stability = Float(min(1, max(0, settings.sixDOFStability)))
        hands.isEnabled = settings.handTrackingEnabled
        headTracker.handsEnabled = settings.handTrackingEnabled
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.settings)
    }
}
