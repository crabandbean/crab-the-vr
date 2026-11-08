//
//  ControllersView.swift
//  JoyVR
//
//  Everything iOS knows about the Nintendo controllers that are paired right
//  now: name, battery, a live picture of the sticks and buttons, and the role
//  each one takes on the PC side.
//

import SwiftUI
import simd

struct ControllersView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gamepad: GamepadTracker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if gamepad.pads.isEmpty {
                    emptyCard
                } else {
                    ForEach(gamepad.pads) { pad in
                        controllerCard(pad)
                    }
                }

                pairingCard
                noteCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Controllers")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Nintendo pads, straight into SteamVR")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    private var emptyCard: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("No controllers yet")
                        .font(.headline)
                    Text("Nothing is paired with this iPhone right now.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
        }
    }

    // MARK: A controller

    private func controllerCard(_ pad: GamepadTracker.Pad) -> some View {
        let snapshot = gamepad.snapshot(for: pad.id)

        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: pad.isNintendo ? "gamecontroller.fill" : "gamecontroller")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pad.name)
                            .font(.headline)
                        Text(pad.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    batteryBadge(pad)
                }

                HStack {
                    Text("Role")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    roleChip(pad)
                }

                Divider().overlay(Theme.stroke)

                preview(snapshot)
            }
        }
    }

    private func preview(_ snapshot: GamepadTracker.Snapshot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                stick("L", value: snapshot.leftStick)
                stick("R", value: snapshot.rightStick)
                Spacer(minLength: 4)
                faceButtons(snapshot.buttons)
            }

            HStack(alignment: .center, spacing: 16) {
                dpad(snapshot.buttons)
                VStack(spacing: 8) {
                    triggerBar("ZL", value: snapshot.leftTrigger)
                    triggerBar("ZR", value: snapshot.rightTrigger)
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 6) {
                chip("L", active: snapshot.buttons.contains(.l))
                chip("R", active: snapshot.buttons.contains(.r))
                chip("+", active: snapshot.buttons.contains(.plus))
                chip("−", active: snapshot.buttons.contains(.minus))
                chip("⌂", active: snapshot.buttons.contains(.home))
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func stick(_ title: String, value: SIMD2<Float>) -> some View {
        let clamped = SIMD2<Float>(max(-1, min(1, value.x)), max(-1, min(1, value.y)))

        return VStack(spacing: 4) {
            ZStack {
                Circle().fill(Theme.cardRaised)
                Circle().stroke(Theme.stroke, lineWidth: 1)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(clamped.x) * 14, y: CGFloat(-clamped.y) * 14)
            }
            .frame(width: 48, height: 48)

            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func faceButtons(_ buttons: GamepadTracker.Buttons) -> some View {
        VStack(spacing: 3) {
            faceButton("X", pressed: buttons.contains(.x))
            HStack(spacing: 3) {
                faceButton("Y", pressed: buttons.contains(.y))
                Color.clear.frame(width: 24, height: 24)
                faceButton("A", pressed: buttons.contains(.a))
            }
            faceButton("B", pressed: buttons.contains(.b))
        }
    }

    private func faceButton(_ title: String, pressed: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 24, height: 24)
            .background(Circle().fill(pressed ? Theme.accent : Theme.cardRaised))
            .foregroundStyle(pressed ? Color.black.opacity(0.85) : Theme.textTertiary)
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
    }

    private func dpad(_ buttons: GamepadTracker.Buttons) -> some View {
        VStack(spacing: 2) {
            dpadArm("arrowtriangle.up.fill", pressed: buttons.contains(.up))
            HStack(spacing: 2) {
                dpadArm("arrowtriangle.left.fill", pressed: buttons.contains(.left))
                Color.clear.frame(width: 18, height: 18)
                dpadArm("arrowtriangle.right.fill", pressed: buttons.contains(.right))
            }
            dpadArm("arrowtriangle.down.fill", pressed: buttons.contains(.down))
        }
    }

    private func dpadArm(_ symbol: String, pressed: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(pressed ? Theme.accent : Theme.cardRaised)
            )
            .foregroundStyle(pressed ? Color.black.opacity(0.85) : Theme.textTertiary)
    }

    private func triggerBar(_ title: String, value: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text(value > 0.05 ? "\(Int((value * 100).rounded()))%" : "—")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cardRaised)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(2, proxy.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 5)
        }
    }

    private func chip(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .frame(minWidth: 28)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent : Theme.cardRaised)
            )
            .foregroundStyle(active ? Color.black.opacity(0.85) : Theme.textSecondary)
    }

    private func batteryBadge(_ pad: GamepadTracker.Pad) -> some View {
        HStack(spacing: 4) {
            if pad.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            Image(systemName: batterySymbol(pad.batteryPercent))
                .font(.system(size: 13))
            if let percent = pad.batteryPercent {
                Text("\(percent)%")
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private func batterySymbol(_ percent: Int?) -> String {
        guard let percent else { return "battery.0percent" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func roleChip(_ pad: GamepadTracker.Pad) -> some View {
        let role = gamepad.role(for: pad)

        return Menu {
            ForEach(GamepadTracker.ControllerRole.allCases) { option in
                Button {
                    gamepad.setRole(option, for: pad)
                } label: {
                    if option == role {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(role.rawValue)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
            .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Guidance

    private var pairingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pair a controller")
                    .font(.headline)

                pairStep(number: "1",
                         title: "Hold the SYNC button",
                         detail: "On a Joy-Con it sits between SL and SR, on a Pro Controller next to the USB-C port. Hold it until the lights start running.")

                pairStep(number: "2",
                         title: "Pick it in Settings › Bluetooth",
                         detail: "iOS does the pairing. Crab the VR lists the pad the moment it is connected.")

                pairStep(number: "3",
                         title: "Give it a role",
                         detail: "Left hand, Right hand, Gamepad, or Ignore to keep it out of SteamVR. The choice is remembered.")
            }
        }
    }

    private func pairStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var noteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.warning)
                    Text("Motion sensors stay on the phone")
                        .font(.subheadline.weight(.semibold))
                }
                Text("iOS does not expose a Joy-Con's motion sensors to apps, so buttons, sticks and triggers are what Crab the VR forwards to your PC. Head tracking still comes from the iPhone.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.stroke)

                Text("Forwarded with every pose while you are linked. A Joy-Con pair that iOS reports as one controller is one row here.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
