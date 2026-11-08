//
//  TrackingSetupView.swift
//  JoyVR
//
//  Three small steps: fit the box so its camera window can see the room, tap
//  once at eye level, then tap once facing forward.
//

import SwiftUI

struct TrackingSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0

    private var status: HeadTrackingStatus { model.trackingStatus }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if status.isSupported {
                        progress
                        stepCard
                        liveCard
                    } else {
                        unsupportedCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { model.beginTrackingSetup() }
        .onDisappear { model.endTrackingSetup() }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up 6DoF")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Placement, eye height, forward")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.cardRaised))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Theme.accent : Theme.stroke)
                    .frame(height: 4)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button(action: advance) {
                Text(primaryTitle)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canAdvance)

            if status.isSupported && step > 0 && step < 3 && !status.isSixDOF {
                Text("Waiting for the camera — the badge will say 6DoF · Good when the room is in view.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var primaryTitle: String {
        if !status.isSupported { return "Close" }
        switch step {
        case 0: return "Placement done"
        case 1: return "Set eye level"
        case 2: return "Set forward"
        default: return "Finish"
        }
    }

    private var canAdvance: Bool {
        guard status.isSupported else { return true }
        switch step {
        case 0: return true
        case 1, 2: return status.isSixDOF
        default: return true
        }
    }

    private func advance() {
        guard status.isSupported else {
            dismiss()
            return
        }
        switch step {
        case 0:
            step = 1
        case 1:
            model.calibrateEyeLevel()
            step = 2
        case 2:
            model.calibrateForward()
            step = 3
        default:
            dismiss()
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepCard: some View {
        switch step {
        case 0:
            stepBody(number: "1",
                     title: "Fit the phone to see the room",
                     detail: "Slide the phone into the box so the camera window on its front is not covered. Point the box at a lit, open part of the room — a wall with furniture or pictures is easier to track than a blank one.",
                     hint: "The camera only has to see the room while you set up; you can look wherever you like afterwards.",
                     symbol: "camera.viewfinder")
        case 1:
            stepBody(number: "2",
                     title: "Set your eye height",
                     detail: "Stand or sit the way you will play, hold the box at eye level, and tap the button. The height your head is at now becomes the height it plays at.",
                     hint: "Leaning and crouching will then move the picture up and down around this height.",
                     symbol: "ruler")
        case 2:
            stepBody(number: "3",
                     title: "Set forward",
                     detail: "Look straight ahead, the way you want the game to start facing, and tap the button. Whatever the box is aimed at now becomes forward.",
                     hint: "You can repeat this any time with Recenter, including from a controller.",
                     symbol: "location.north.line")
        default:
            stepBody(number: "✓",
                     title: "6DoF is ready",
                     detail: "Position and rotation both go to your PC now. If the view ever drifts, tap Recenter; if the camera loses the room, the gyro keeps the view turning and the badge says 3DoF fallback.",
                     hint: "The stability slider in Settings trades a little smoothing for a little lag.",
                     symbol: "checkmark.seal")
        }
    }

    private func stepBody(number: String,
                          title: String,
                          detail: String,
                          hint: String,
                          symbol: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(number)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.accent.opacity(0.18)))
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var liveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TrackingBadgeView(status: status)
                    Spacer()
                    if status.isSixDOF {
                        Text(status.note)
                            .font(.caption2)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var detailText: String {
        switch status.mode {
        case .sixDOF:
            return "The camera is tracking the room and the gyro is filling in between."
        case .threeDOF:
            return status.note.isEmpty
                ? "Waiting for the camera to see the room."
                : status.note
        case .off:
            return "Tracking is not running yet."
        }
    }

    private var unsupportedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("This iPhone cannot see the room")
                    .font(.headline)
                Text("ARKit world tracking is not available on this iPhone, so Crab the VR sends rotation only (3DoF). Everything else works the same.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
