//
//  VRStreamView.swift
//  JoyVR
//
//  The full screen picture that goes inside the box. Tapping shows the overlay;
//  it hides itself again after a few seconds. A paired controller can show and
//  hide it too, so the phone can stay in the box.
//

import SwiftUI
import UIKit

struct VRStreamView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var gamepad: GamepadTracker
    @EnvironmentObject private var hands: HandTracker
    @State private var hideWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.isConnected {
                VRView(pipeline: model.pipeline,
                       testPattern: model.settings.showTestPattern,
                       picture: model.pictureTuning)
                    .ignoresSafeArea()
            } else {
                PlaygroundView()
                    .ignoresSafeArea()
            }

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(count: 2) { model.recenter() }
                .onTapGesture { toggleControls() }
                .onLongPressGesture(minimumDuration: 0.7) { model.toggleVRPause() }

            if model.isVRPaused {
                ZStack {
                    Color.black.opacity(0.62).ignoresSafeArea()
                    VStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 42, weight: .semibold))
                        Text("Paused")
                            .font(.title3.weight(.semibold))
                        Text("Long-press inside the box to resume")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if model.vrOverlayVisible {
                overlay.transition(.opacity)
            }

            VStack {
                Spacer()
                HStack {
                    TrackingBadgeView(status: model.trackingStatus, onDark: true)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .allowsHitTesting(false)

            if model.settings.handTrackingEnabled && model.isConnected {
                GeometryReader { proxy in
                    HandSkeletonOverlay(hands: hands.overlayHands)
                        .position(x: proxy.size.width * 0.25,
                                  y: proxy.size.height - 76)
                }
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.vrOverlayVisible)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            OrientationManager.shared.lock(.landscape)
            UIApplication.shared.isIdleTimerDisabled = true
            model.vrOverlayVisible = true
            scheduleHide()
        }
        .onChange(of: model.vrOverlayVisible) { _, visible in
            if visible { scheduleHide() }
        }
        .onDisappear {
            hideWork?.cancel()
            OrientationManager.shared.lock(.all)
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var overlay: some View {
        VStack {
            HStack(spacing: 12) {
                circleButton(systemName: "xmark") {
                    model.exitVR()
                }

                Spacer()

                HStack(spacing: 8) {
                    StatusDot(isOn: true)
                    Text(statusText)
                        .font(.caption.weight(.medium))
                    if let pad = gamepad.primaryPad {
                        Divider()
                            .frame(height: 12)
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 12, weight: .semibold))
                        if let battery = pad.batteryText {
                            Text(battery)
                                .font(.caption.weight(.semibold))
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(.ultraThinMaterial))

                Spacer()

                circleButton(systemName: "arrow.trianglehead.counterclockwise") {
                    model.recenter()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)

            Spacer()

            if !model.isConnected {
                VStack(spacing: 6) {
                    Text("Playground — no PC needed")
                        .font(.caption.weight(.semibold))
                    Text("Look around, and hold your hands in front of the box's camera window.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.bottom, 18)
            }
        }
        .onTapGesture { scheduleHide() }
    }

    private var statusText: String {
        guard model.isConnected else { return "Playground" }
        let name = model.serverName.isEmpty ? "PC" : model.serverName
        return "\(name) · \(model.poseRate) Hz"
    }

    private func circleButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
    }

    private func toggleControls() {
        model.vrOverlayVisible.toggle()
        if model.vrOverlayVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            model.vrOverlayVisible = false
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
