//
//  LinkView.swift
//  JoyVR
//

import SwiftUI

struct LinkView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gamepad: GamepadTracker
    @State private var showManualEntry = false
    @State private var showTrackingSetup = false
    @State private var manualAddress = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pcCard
                trackingCard
                controllerCard
                summaryCard
                actionButtons
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showManualEntry) { manualEntrySheet }
        .sheet(isPresented: $showTrackingSetup) {
            TrackingSetupView()
                .environmentObject(model)
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Crab the VR")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("SteamVR, wirelessly, on your iPhone")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var pcCard: some View {
        Card {
            switch model.linkState {
            case .connected(let host, let name):
                connectedContent(host: host, name: name)
            case .connecting(let host):
                connectingContent(host: host)
            case .failed(let message):
                failedContent(message)
            case .idle:
                idleContent
            }
        }
    }

    private func connectedContent(host: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? host : name)
                        .font(.headline)
                    Text("Connected · \(host)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                StatusDot(isOn: true)
            }
            Button {
                model.disconnect()
            } label: {
                Text("Disconnect")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func connectingContent(host: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connecting…")
                    .font(.headline)
                Text(host)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text("Not connected")
                    .font(.headline)
                Spacer()
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try again") {
                    if let host = model.rememberedHost {
                        model.connect(host: host)
                    } else {
                        model.startScan()
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Enter address") { showManualEntry = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "wifi")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isScanning ? "Looking for your PC…" : "No PC connected")
                        .font(.headline)
                    Text(model.isScanning ? "Broadcasting on your network" : "Same Wi-Fi as your PC")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if model.isScanning {
                    ProgressView().tint(Theme.accent)
                }
            }

            if !model.discovered.isEmpty {
                VStack(spacing: 8) {
                    ForEach(model.discovered) { pc in
                        pcRow(pc)
                    }
                }
            } else if let host = model.rememberedHost {
                pcRow(Discovery.FoundPC(address: host,
                                        name: model.rememberedName ?? host,
                                        port: JVRProtocol.streamPort))
            }

            HStack(spacing: 10) {
                Button("Find my PC") { model.startScan() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Enter address") { showManualEntry = true }
                    .buttonStyle(SecondaryButtonStyle())
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pcRow(_ pc: Discovery.FoundPC) -> some View {
        Button {
            model.connect(host: pc.address, port: pc.port, name: pc.name)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pc.name).font(.subheadline.weight(.semibold))
                    Text(pc.address)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.cardRaised)
            )
        }
        .buttonStyle(.plain)
    }

    private var summaryCard: some View {
        Card {
            VStack(spacing: 0) {
                summaryRow(title: "Quality",
                           value: "\(model.settings.quality.title) · \(model.settings.quality.detail) · \(model.settings.bitrateMbps) Mbps")
                Divider().overlay(Theme.stroke)
                summaryRow(title: "Refresh", value: "\(model.settings.refreshRate) Hz")
                Divider().overlay(Theme.stroke)
                summaryRow(title: "Test pattern", value: model.settings.showTestPattern ? "On" : "Off")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTab = .settings }
    }

    private func summaryRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 11)
    }

    private var trackingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "gyroscope")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(model.headTrackingAvailable ? Theme.accent : Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Head tracking")
                            .font(.headline)
                        Text(trackingDetail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    TrackingBadgeView(status: model.trackingStatus)
                    Spacer()
                    Button("Recenter") { model.recenter() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .disabled(!model.headTrackingAvailable)
                }

                Divider().overlay(Theme.stroke)

                Toggle(isOn: $model.settings.sixDOFEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("6DoF head tracking")
                            .font(.subheadline.weight(.medium))
                        Text("ARKit watches the room for position; the gyro fills in between.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .disabled(!model.headTrackingAvailable)

                if model.settings.sixDOFEnabled {
                    Button("Set up 6DoF") { showTrackingSetup = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!ARKitHeadSource.isSupported)
                }
            }
        }
    }

    private var trackingDetail: String {
        guard model.headTrackingAvailable else { return "Motion sensors unavailable" }
        guard ARKitHeadSource.isSupported else { return "3DoF · this iPhone cannot see the room" }
        return model.settings.sixDOFEnabled ? "6DoF · ARKit and gyro" : "3DoF · gyro"
    }

    private var controllerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(gamepad.pads.isEmpty ? Theme.textSecondary : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controllerTitle)
                            .font(.headline)
                        Text(controllerDetail)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let pad = gamepad.primaryPad, let battery = pad.batteryText {
                        Text(battery)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(pad.isCharging ? Theme.accent : Theme.textSecondary)
                    }
                }

                Divider().overlay(Theme.stroke)

                Toggle(isOn: $model.settings.controllerLocomotion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Move with the controller")
                            .font(.subheadline.weight(.medium))
                        Text("Left stick walks · right stick turns · shoulders snap turn.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .disabled(gamepad.pads.isEmpty)

                Text(gamepad.pads.isEmpty
                     ? "Pair a Joy-Con or a Switch Pro Controller in Settings › Bluetooth. Crab the VR picks it up by itself."
                     : "Y recenters · Menu shows the overlay · B leaves VR.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var controllerTitle: String {
        gamepad.primaryPad?.name ?? "Nintendo controller"
    }

    private var controllerDetail: String {
        guard let pad = gamepad.primaryPad else {
            return "Not connected yet"
        }
        return pad.detail
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                model.enterVR()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isConnected ? "visionpro" : "hand.wave")
                    Text(model.isConnected ? "Enter VR" : "Enter Playground")
                }
            }
            .buttonStyle(PrimaryButtonStyle())

            Text(model.isConnected
                 ? (model.isControllerMoving
                    ? "Put the phone in the box, then press A on your controller or tap Enter VR."
                    : "Put the phone in the box before you tap Enter VR.")
                 : "No PC needed: put the phone in the box and look around with your hands and controller.")
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 4)
    }

    // MARK: Manual address

    private var manualEntrySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your PC's address")
                .font(.title3.weight(.semibold))
            TextField("192.168.1.20", text: $manualAddress)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardRaised))
            Text("You can add :port at the end. The default is \(JVRProtocol.streamPort).")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button("Connect") {
                let trimmed = manualAddress.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                let parts = trimmed.split(separator: ":")
                let host = String(parts[0])
                let port = parts.count > 1 ? (UInt16(parts[1]) ?? JVRProtocol.streamPort) : JVRProtocol.streamPort
                showManualEntry = false
                manualAddress = ""
                model.connect(host: host, port: port)
            }
            .buttonStyle(PrimaryButtonStyle())
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(300)])
    }
}
