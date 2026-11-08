//
//  GamepadTracker.swift
//  JoyVR
//
//  Nintendo Switch controllers reach iOS through the Game Controller
//  framework: a paired Joy-Con or Switch Pro Controller shows up by itself,
//  with its sticks, buttons and battery. This class watches those connections,
//  keeps a live picture of every pad for the Controllers screen, hands the
//  sticks to the pose loop and forwards the buttons and axes to the PC.
//

import Combine
import Foundation
import GameController
import simd

final class GamepadTracker: ObservableObject {

    enum Action {
        case recenter
        case enterVR
        case exitVR
        case toggleOverlay
        case snapTurnLeft
        case snapTurnRight
    }

    /// What a controller is used as on the PC side.
    enum ControllerRole: String, CaseIterable, Codable, Identifiable {
        case leftHand = "Left hand"
        case rightHand = "Right hand"
        case gamepad = "Gamepad"
        case ignore = "Ignore"

        var id: String { rawValue }

        /// 0 left hand, 1 right hand, 2 gamepad, in the pose packet.
        var packetValue: UInt8 {
            switch self {
            case .leftHand: return 0
            case .rightHand: return 1
            case .gamepad: return 2
            case .ignore: return 2
            }
        }
    }

    /// The button bit field of a pose packet record, in the Nintendo layout.
    struct Buttons: OptionSet, Hashable {
        let rawValue: UInt16

        static let a = Buttons(rawValue: 1 << 0)
        static let b = Buttons(rawValue: 1 << 1)
        static let x = Buttons(rawValue: 1 << 2)
        static let y = Buttons(rawValue: 1 << 3)
        static let l = Buttons(rawValue: 1 << 4)
        static let r = Buttons(rawValue: 1 << 5)
        static let zl = Buttons(rawValue: 1 << 6)
        static let zr = Buttons(rawValue: 1 << 7)
        static let plus = Buttons(rawValue: 1 << 8)
        static let minus = Buttons(rawValue: 1 << 9)
        static let home = Buttons(rawValue: 1 << 10)
        static let capture = Buttons(rawValue: 1 << 11)
        static let up = Buttons(rawValue: 1 << 12)
        static let down = Buttons(rawValue: 1 << 13)
        static let left = Buttons(rawValue: 1 << 14)
        static let right = Buttons(rawValue: 1 << 15)
    }

    /// One frame of what the user is doing on a pad, for the live preview.
    struct Snapshot: Equatable {
        var buttons: Buttons = []
        var leftStick = SIMD2<Float>(0, 0)
        var rightStick = SIMD2<Float>(0, 0)
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
    }

    struct Pad: Identifiable, Equatable {
        let id: ObjectIdentifier
        var name: String
        var detail: String
        var batteryPercent: Int?
        var isCharging: Bool
        var hasMotion: Bool
        var hasSticks: Bool
        var isNintendo: Bool

        var batteryText: String? {
            guard let batteryPercent else { return nil }
            return "\(batteryPercent)%"
        }

        /// Roles are remembered per kind of controller, since iOS gives us no
        /// hardware id that survives a reconnect.
        var roleKey: String { name }
    }

    /// What the pose loop reads. Written from the controller callbacks, read
    /// from the link's own queue, so it lives behind a lock.
    struct Sticks: Equatable {
        var move = SIMD2<Float>(0, 0)
        var turn: Float = 0
    }

    @Published private(set) var pads: [Pad] = []
    @Published private(set) var roles: [String: ControllerRole] = [:]
    @Published private(set) var snapshots: [ObjectIdentifier: Snapshot] = [:]

    var onAction: ((Action) -> Void)?

    private static let rolesKey = "joyvr.controllerRoles"

    private let lock = NSLock()
    private var stickState = Sticks()
    private var snapshotStorage: [ObjectIdentifier: Snapshot] = [:]
    private var forwardCache: [PhonePacket.Controller] = []
    private var publishWork: DispatchWorkItem?

    private var slots: [ObjectIdentifier: UInt8] = [:]
    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var observers: [NSObjectProtocol] = []
    private var batteryTimer: Timer?

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.rolesKey) as? [String: String] {
            var restored: [String: ControllerRole] = [:]
            for (key, value) in saved {
                if let role = ControllerRole(rawValue: value) {
                    restored[key] = role
                }
            }
            roles = restored
        }

        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: .GCControllerDidConnect,
                                           object: nil,
                                           queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.adopt(controller)
        })

        observers.append(center.addObserver(forName: .GCControllerDidDisconnect,
                                           object: nil,
                                           queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.release(controller)
        })

        // Battery levels are not pushed to us, so ask again now and then.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer

        for controller in GCController.controllers() {
            adopt(controller)
        }
    }

    deinit {
        publishWork?.cancel()
        batteryTimer?.invalidate()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var primaryPad: Pad? {
        pads.first
    }

    /// Left stick as (x, y) with y up the way a game reads it, and the right
    /// stick's horizontal axis for turning.
    var currentSticks: Sticks {
        lock.lock()
        defer { lock.unlock() }
        return stickState
    }

    /// What goes in the pose packets, one record per controller that has a role
    /// other than Ignore. Safe to call from the link's queue.
    var forwardedControllers: [PhonePacket.Controller] {
        lock.lock()
        defer { lock.unlock() }
        return forwardCache
    }

    // MARK: Roles

    func role(for pad: Pad) -> ControllerRole {
        if let saved = roles[pad.roleKey] {
            return saved
        }
        return defaultRole(for: pad)
    }

    func setRole(_ role: ControllerRole, for pad: Pad) {
        roles[pad.roleKey] = role
        UserDefaults.standard.set(roles.mapValues { $0.rawValue }, forKey: Self.rolesKey)
        rebuildForwardCache()
    }

    func snapshot(for id: ObjectIdentifier) -> Snapshot {
        snapshots[id] ?? Snapshot()
    }

    private func defaultRole(for pad: Pad) -> ControllerRole {
        switch pad.name {
        case "Joy-Con (L)":
            return .leftHand
        case "Joy-Con (R)":
            return .rightHand
        default:
            return .gamepad
        }
    }

    // MARK: Connections

    private func adopt(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        guard controllers[id] == nil else { return }

        controller.handlerQueue = .main
        if controller.playerIndex == .indexUnset {
            controller.playerIndex = .index1
        }

        var slot: UInt8 = 0
        let used = Set(slots.values)
        while slot < 4, used.contains(slot) {
            slot += 1
        }
        slots[id] = slot

        if let pad = controller.extendedGamepad {
            pad.valueChangedHandler = { [weak self, weak pad] _, _ in
                guard let self, let pad else { return }
                self.storeSticks(from: pad)
                self.record(snapshotFrom: pad, id: id)
            }

            bind(pad.buttonA, to: .enterVR)
            bind(pad.buttonB, to: .exitVR)
            bind(pad.buttonX, to: .recenter)
            bind(pad.buttonY, to: .recenter)
            bind(pad.buttonMenu, to: .toggleOverlay)
            bind(pad.buttonOptions, to: .toggleOverlay)
            bind(pad.buttonHome, to: .recenter)
            bind(pad.leftShoulder, to: .snapTurnLeft)
            bind(pad.rightShoulder, to: .snapTurnRight)

            record(snapshotFrom: pad, id: id)
        }

        if let pad = controller.microGamepad {
            pad.valueChangedHandler = { [weak self] pad, _ in
                self?.storeSticks(from: pad)
                self?.record(snapshotFrom: pad, id: id)
            }

            bind(pad.buttonA, to: .enterVR)
            bind(pad.buttonX, to: .recenter)
            bind(pad.buttonMenu, to: .toggleOverlay)

            record(snapshotFrom: pad, id: id)
        }

        controllers[id] = controller
        refresh()
    }

    private func release(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        controllers.removeValue(forKey: id)
        slots.removeValue(forKey: id)

        controller.extendedGamepad?.valueChangedHandler = nil
        controller.microGamepad?.valueChangedHandler = nil

        lock.lock()
        snapshotStorage.removeValue(forKey: id)
        lock.unlock()

        if let remaining = controllers.values.first(where: { $0.extendedGamepad != nil }),
           let pad = remaining.extendedGamepad {
            storeSticks(from: pad)
        } else if let remaining = controllers.values.first(where: { $0.microGamepad != nil }),
                  let pad = remaining.microGamepad {
            storeSticks(from: pad)
        } else {
            setSticks(Sticks())
        }

        refresh()
        publishSnapshots()
    }

    private func bind(_ button: GCControllerButtonInput?, to action: Action) {
        button?.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.onAction?(action)
        }
    }

    // MARK: Input

    private func storeSticks(from pad: GCExtendedGamepad) {
        var sticks = Sticks()
        sticks.move = SIMD2<Float>(pad.leftThumbstick.xAxis.value,
                                   pad.leftThumbstick.yAxis.value)

        if abs(sticks.move.x) < 0.001, abs(sticks.move.y) < 0.001 {
            sticks.move = SIMD2<Float>(pad.dpad.xAxis.value, pad.dpad.yAxis.value)
        }
        sticks.turn = pad.rightThumbstick.xAxis.value

        setSticks(sticks)
    }

    private func storeSticks(from pad: GCMicroGamepad) {
        var sticks = Sticks()
        sticks.move = SIMD2<Float>(pad.dpad.xAxis.value, pad.dpad.yAxis.value)
        setSticks(sticks)
    }

    private func setSticks(_ sticks: Sticks) {
        lock.lock()
        stickState = sticks
        lock.unlock()
    }

    private func record(snapshotFrom pad: GCExtendedGamepad, id: ObjectIdentifier) {
        var buttons: Buttons = []
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonB.isPressed { buttons.insert(.b) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonY.isPressed { buttons.insert(.y) }
        if pad.leftShoulder.isPressed { buttons.insert(.l) }
        if pad.rightShoulder.isPressed { buttons.insert(.r) }
        if pad.leftTrigger.value > 0.5 { buttons.insert(.zl) }
        if pad.rightTrigger.value > 0.5 { buttons.insert(.zr) }
        if pad.buttonMenu.isPressed { buttons.insert(.plus) }
        if pad.buttonOptions?.isPressed == true { buttons.insert(.minus) }
        if pad.buttonHome?.isPressed == true { buttons.insert(.home) }
        if pad.dpad.up.isPressed { buttons.insert(.up) }
        if pad.dpad.down.isPressed { buttons.insert(.down) }
        if pad.dpad.left.isPressed { buttons.insert(.left) }
        if pad.dpad.right.isPressed { buttons.insert(.right) }

        var snapshot = Snapshot()
        snapshot.buttons = buttons
        snapshot.leftStick = SIMD2<Float>(pad.leftThumbstick.xAxis.value,
                                          pad.leftThumbstick.yAxis.value)
        snapshot.rightStick = SIMD2<Float>(pad.rightThumbstick.xAxis.value,
                                           pad.rightThumbstick.yAxis.value)
        snapshot.leftTrigger = pad.leftTrigger.value
        snapshot.rightTrigger = pad.rightTrigger.value
        store(snapshot, id: id)
    }

    private func record(snapshotFrom pad: GCMicroGamepad, id: ObjectIdentifier) {
        var buttons: Buttons = []
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonMenu.isPressed { buttons.insert(.plus) }
        if pad.dpad.up.isPressed { buttons.insert(.up) }
        if pad.dpad.down.isPressed { buttons.insert(.down) }
        if pad.dpad.left.isPressed { buttons.insert(.left) }
        if pad.dpad.right.isPressed { buttons.insert(.right) }

        var snapshot = Snapshot()
        snapshot.buttons = buttons
        snapshot.leftStick = SIMD2<Float>(pad.dpad.xAxis.value,
                                          pad.dpad.yAxis.value)
        store(snapshot, id: id)
    }

    private func store(_ snapshot: Snapshot, id: ObjectIdentifier) {
        lock.lock()
        let previous = snapshotStorage[id]
        snapshotStorage[id] = snapshot
        lock.unlock()

        guard previous != snapshot else { return }
        schedulePublish()
        rebuildForwardCache()
    }

    /// The preview does not need every sample: 20 Hz is smooth and keeps the
    /// rest of the app from redrawing at controller rate.
    private func schedulePublish() {
        guard publishWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.publishWork = nil
            self.publishSnapshots()
        }
        publishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func publishSnapshots() {
        lock.lock()
        let current = snapshotStorage
        lock.unlock()
        snapshots = current
    }

    private func storedSnapshot(for id: ObjectIdentifier) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStorage[id] ?? Snapshot()
    }

    // MARK: Forwarding

    private func rebuildForwardCache() {
        var records: [PhonePacket.Controller] = []
        for pad in pads {
            let role = role(for: pad)
            guard role != .ignore, let slot = slots[pad.id] else { continue }
            let snapshot = storedSnapshot(for: pad.id)
            records.append(PhonePacket.Controller(
                slot: slot,
                role: role.packetValue,
                buttons: snapshot.buttons.rawValue,
                leftStick: Self.int16(snapshot.leftStick),
                rightStick: Self.int16(snapshot.rightStick),
                leftTrigger: Self.triggerByte(snapshot.leftTrigger),
                rightTrigger: Self.triggerByte(snapshot.rightTrigger),
                battery: UInt8(clamping: pad.batteryPercent ?? 255)
            ))
        }

        lock.lock()
        forwardCache = records
        lock.unlock()
    }

    private static func int16(_ value: SIMD2<Float>) -> SIMD2<Int16> {
        SIMD2<Int16>(Int16(clamping: Int((max(-1, min(1, value.x)) * 32767).rounded())),
                     Int16(clamping: Int((max(-1, min(1, value.y)) * 32767).rounded())))
    }

    private static func triggerByte(_ value: Float) -> UInt8 {
        UInt8(clamping: Int((max(0, min(1, value)) * 255).rounded()))
    }

    // MARK: Describing the pads

    private func refresh() {
        pads = controllers.values
            .map(makePad)
            .sorted { lhs, rhs in
                if lhs.isNintendo != rhs.isNintendo {
                    return lhs.isNintendo
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        rebuildForwardCache()
    }

    private func makePad(_ controller: GCController) -> Pad {
        let name = displayName(for: controller)
        let vendor = controller.vendorName ?? ""

        var batteryPercent: Int?
        var isCharging = false
        if let battery = controller.battery {
            let level = max(0, min(1, battery.batteryLevel))
            batteryPercent = Int((level * 100).rounded())
            isCharging = battery.batteryState == .charging || battery.batteryState == .full
        }

        let hasMotion = controller.motion != nil
        let hasSticks = controller.extendedGamepad != nil || controller.microGamepad != nil

        var parts: [String] = []
        if hasMotion { parts.append("6-axis motion") }
        if hasSticks { parts.append("sticks") }
        if parts.isEmpty, !vendor.isEmpty { parts.append(vendor) }

        let lowered = (name + " " + vendor).lowercased()
        let isNintendo = lowered.contains("nintendo")
            || lowered.contains("joy-con")
            || lowered.contains("switch pro")

        return Pad(id: ObjectIdentifier(controller),
                   name: name,
                   detail: parts.isEmpty ? "buttons" : parts.joined(separator: " · "),
                   batteryPercent: batteryPercent,
                   isCharging: isCharging,
                   hasMotion: hasMotion,
                   hasSticks: hasSticks,
                   isNintendo: isNintendo)
    }

    private func displayName(for controller: GCController) -> String {
        let vendor = controller.vendorName ?? ""
        let lowered = vendor.lowercased()

        if lowered.contains("joy") && lowered.contains("con") {
            if lowered.contains("left") { return "Joy-Con (L)" }
            if lowered.contains("right") { return "Joy-Con (R)" }
            return "Joy-Con"
        }
        if lowered.contains("pro controller") || lowered.contains("switch pro") {
            return "Switch Pro Controller"
        }
        if lowered.contains("nintendo") {
            return vendor
        }
        return vendor.isEmpty ? "Controller" : vendor
    }
}
