//
//  SettingsView.swift
//  JoyVR
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gamepad: GamepadTracker

    private var bitrateBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.bitrateMbps) },
            set: { model.settings.bitrateMbps = Int($0.rounded()) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .padding(.bottom, 2)

                SectionTitle(text: "Stream")

                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Quality")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Picker("Quality", selection: $model.settings.quality) {
                            ForEach(StreamSettings.Quality.allCases) { quality in
                                Text(quality.title).tag(quality)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(model.settings.quality.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)

                        Divider().overlay(Theme.stroke)

                        HStack {
                            Text("Bitrate")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(model.settings.bitrateMbps) Mbps")
                                .font(.subheadline.weight(.medium))
                        }
                        Slider(value: bitrateBinding, in: 10...150, step: 5)
                            .tint(Theme.accent)

                        Divider().overlay(Theme.stroke)

                        Text("Refresh")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Picker("Refresh", selection: $model.settings.refreshRate) {
                            ForEach(StreamSettings.refreshChoices, id: \.self) { rate in
                                Text("\(rate) Hz").tag(rate)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                SectionTitle(text: "Controller & tracking")

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $model.settings.sixDOFEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("6DoF head tracking")
                                    .font(.subheadline.weight(.medium))
                                Text("ARKit watches the room for position; the gyro covers the moments in between.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Theme.accent)

                        if model.settings.sixDOFEnabled {
                            valueRow(title: "Stability",
                                     value: "\(Int((model.settings.sixDOFStability * 100).rounded()))%")
                            Slider(value: $model.settings.sixDOFStability, in: 0...1)
                                .tint(Theme.accent)
                            Text("Low follows your head faster; high smooths the small shakes of holding the box.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Toggle(isOn: $model.settings.handTrackingEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("See your hands")
                                    .font(.subheadline.weight(.medium))
                                Text("Tracks up to two hands with the camera and sends them to the PC as controllers, alongside any Nintendo pads.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Theme.accent)

                        Divider().overlay(Theme.stroke)

                        Toggle(isOn: $model.settings.controllerLocomotion) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Move with the controller")
                                    .font(.subheadline.weight(.medium))
                                Text("Left stick walks, right stick turns, the shoulders snap turn.")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Theme.accent)

                        if model.settings.controllerLocomotion {
                            valueRow(title: "Walking speed",
                                     value: String(format: "%.1f m/s", model.settings.walkSpeed))
                            Slider(value: $model.settings.walkSpeed, in: 0.4...2.4, step: 0.1)
                                .tint(Theme.accent)

                            valueRow(title: "Turn speed",
                                     value: "\(Int(model.settings.turnSpeed)) °/s")
                            Slider(value: $model.settings.turnSpeed, in: 30...240, step: 10)
                                .tint(Theme.accent)
                        }
                    }
                }

                SectionTitle(text: "Controller")

                controllerCard

                SectionTitle(text: "Headset")

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Picture")
                            .font(.subheadline.weight(.medium))
                        Text("Distortion, chromatic aberration, IPD, brightness and the wireframe test pattern live on the Tune tab.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("They apply straight away, in VR as well.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionTitle(text: "PC")

                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        if let host = model.rememberedHost {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.rememberedName ?? host)
                                        .font(.subheadline.weight(.medium))
                                    Text(host)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Button("Forget") {
                                    if model.isConnected { model.disconnect() }
                                    model.forgetSavedPC()
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                            }
                        } else {
                            Text("No PC saved yet.")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }

                        Divider().overlay(Theme.stroke)

                        Text("Stream changes apply the next time you connect.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    // MARK: Pieces

    private func valueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }

    private var controllerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if gamepad.pads.isEmpty {
                    Text("No controller yet")
                        .font(.subheadline.weight(.medium))
                    Text("Pair a Joy-Con or a Switch Pro Controller in iOS Settings › Bluetooth, then come back. Crab the VR picks it up automatically.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(gamepad.pads) { pad in
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pad.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(pad.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if let battery = pad.batteryText {
                                Text(battery)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(pad.isCharging ? Theme.accent : Theme.textSecondary)
                            }
                        }
                    }

                    Text("Y recenters · Menu shows the overlay · B leaves VR.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}
