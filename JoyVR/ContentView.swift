//
//  ContentView.swift
//  JoyVR
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $model.selectedTab) {
            LinkView()
                .tabItem { Label("Link", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppModel.Tab.link)

            ControllersView()
                .tabItem { Label("Controllers", systemImage: "gamecontroller") }
                .tag(AppModel.Tab.controllers)

            TuneView()
                .tabItem { Label("Tune", systemImage: "speedometer") }
                .tag(AppModel.Tab.tune)

            SetupView()
                .tabItem { Label("PC", systemImage: "desktopcomputer") }
                .tag(AppModel.Tab.pc)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(AppModel.Tab.settings)
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: $model.isInVR) {
            VRStreamView()
                .environmentObject(model)
                .environmentObject(model.gamepad)
                .environmentObject(model.hands)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.isInVR {
                model.exitVR()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
        .environmentObject(GamepadTracker())
        .environmentObject(HandTracker())
}
