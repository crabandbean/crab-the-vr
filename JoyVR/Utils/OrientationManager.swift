//
//  OrientationManager.swift
//  JoyVR
//
//  The VR view needs the phone in landscape; everything else can rotate freely.
//

import UIKit

final class OrientationManager {
    static let shared = OrientationManager()

    private(set) var mask: UIInterfaceOrientationMask = .all

    func lock(_ mask: UIInterfaceOrientationMask) {
        guard mask != self.mask else { return }
        self.mask = mask
        apply()
    }

    private func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
