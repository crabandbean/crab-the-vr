//
//  TuneView.swift
//  JoyVR
//
//  Live stream numbers on top, then the picture controls that matter in a
//  phone headset.
//

import SwiftUI

struct TuneView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingProfiles = false

    private var diagnostics: StreamDiagnostics { model.diagnostics }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                SectionTitle(text: "Profile")

                profileCard

                SectionTitle(text: "Diagnostics")

                diagnosticsCard

                SectionTitle(text: "Picture")

                pictureCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingProfiles) {
            ProfilesView()
                .environmentObject(model)
        }
    }

    private var profileCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.activeProfile?.name ?? "Current setup")
                        .font(.headline)
                    Text(profileDetail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("Profiles") {
                    showingProfiles = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    private var profileDetail: String {
        guard let profile = model.activeProfile else {
            return "Save a lens and comfort setup to switch to it with one tap."
        }
        return profile.game.isEmpty ? "Any game · \(profile.summary)" : "for \(profile.game) · \(profile.summary)"
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tune")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Live stream numbers and the picture")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    // MARK: Diagnostics

    private var diagnosticsCard: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    StatusDot(isOn: model.isConnected)
                    Text(model.isConnected ? "Streaming · \(model.serverName.isEmpty ? "PC" : model.serverName)" : "Not linked")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
                .padding(.bottom, 10)

                metricRow("Round trip", milliseconds(diagnostics.roundTripMs))
                Divider().overlay(Theme.stroke)
                metricRow("Pose latency", milliseconds(diagnostics.poseLatencyMs))
                Divider().overlay(Theme.stroke)
                metricRow("Pose rate", "\(diagnostics.poseRate) Hz")
                Divider().overlay(Theme.stroke)
                metricRow("Decoded", "\(diagnostics.decodedFPS) fps")
                Divider().overlay(Theme.stroke)
                metricRow("Dropped packets", "\(diagnostics.droppedPackets)")
                Divider().overlay(Theme.stroke)
                metricRow("Incoming bitrate", bitrate(diagnostics.incomingKbps))
                Divider().overlay(Theme.stroke)
                metricRow("Encoder bitrate", encoderBitrate)
                Divider().overlay(Theme.stroke)
                metricRow("Tracking", diagnostics.trackingMode)

                if diagnostics.isAdapting {
                    HStack(spacing: 8) {
                        Image(systemName: "speedometer")
                            .font(.caption)
                            .foregroundStyle(Theme.warning)
                        Text("Bitrate reduced to keep the picture smooth; it climbs back when the link is clean.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                }

                if !model.isConnected {
                    Text("Link a PC to see live numbers.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
            }
        }
    }

    private var encoderBitrate: String {
        guard diagnostics.effectiveBitrateKbps > 0 else { return "—" }
        let current = bitrate(diagnostics.effectiveBitrateKbps)
        if diagnostics.isAdapting {
            return "\(current) of \(bitrate(diagnostics.targetBitrateKbps))"
        }
        return current
    }

    private func milliseconds(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value) ms"
    }

    private func bitrate(_ kbps: Int) -> String {
        guard kbps > 0 else { return "—" }
        return String(format: "%.1f Mbps", Double(kbps) / 1000)
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
        }
        .padding(.vertical, 10)
    }

    // MARK: Picture

    private var pictureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                pictureSlider(title: "Barrel distortion k1",
                              value: "\(String(format: "%.2f", model.settings.distortionK1))",
                              binding: $model.settings.distortionK1,
                              range: 0...0.6,
                              step: 0.01)

                Divider().overlay(Theme.stroke)

                pictureSlider(title: "Barrel distortion k2",
                              value: "\(String(format: "%.2f", model.settings.distortionK2))",
                              binding: $model.settings.distortionK2,
                              range: 0...0.2,
                              step: 0.01)

                Divider().overlay(Theme.stroke)

                pictureSlider(title: "Chromatic aberration",
                              value: "\(String(format: "%.3f", model.settings.chromaticAberration))",
                              binding: $model.settings.chromaticAberration,
                              range: 0...0.02,
                              step: 0.001)

                Divider().overlay(Theme.stroke)

                pictureSlider(title: "Eye offset (IPD)",
                              value: "\(String(format: "%.1f", model.settings.ipdMillimeters)) mm",
                              binding: $model.settings.ipdMillimeters,
                              range: 50...75,
                              step: 0.5)

                Divider().overlay(Theme.stroke)

                pictureSlider(title: "Brightness",
                              value: "\(String(format: "%.2f", model.settings.brightness))",
                              binding: $model.settings.brightness,
                              range: 0.4...1.6,
                              step: 0.05)

                Divider().overlay(Theme.stroke)

                pictureSlider(title: "Saturation",
                              value: "\(String(format: "%.2f", model.settings.saturation))",
                              binding: $model.settings.saturation,
                              range: 0...2,
                              step: 0.05)

                Divider().overlay(Theme.stroke)

                Toggle(isOn: $model.settings.showTestPattern) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wireframe test pattern")
                            .font(.subheadline.weight(.medium))
                        Text("Skips the video and draws the alignment grid instead.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)

                Text("Changes apply straight away, and the IPD goes to the PC with the next pose.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pictureSlider(title: String,
                               value: String,
                               binding: Binding<Double>,
                               range: ClosedRange<Double>,
                              step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: step)
                .tint(Theme.accent)
        }
    }
}
