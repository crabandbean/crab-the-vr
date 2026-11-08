//
//  JoyVRApp.swift
//  JoyVR
//

import SwiftUI
import UIKit

final class JoyVRAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationManager.shared.mask
    }
}

@main
struct JoyVRApp: App {
    @UIApplicationDelegateAdaptor(JoyVRAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.gamepad)
                .environmentObject(model.hands)
                .preferredColorScheme(.dark)
        }
    }
}
