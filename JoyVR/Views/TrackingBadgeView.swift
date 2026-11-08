//
//  TrackingBadgeView.swift
//  JoyVR
//
//  The live 6DoF / 3DoF badge, used on the Link screen and inside VR.
//

import SwiftUI

struct TrackingBadgeView: View {
    let status: HeadTrackingStatus
    var onDark = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(status.badgeTitle)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(onDark ? Color.white.opacity(0.9) : Theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(onDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Theme.cardRaised))
        )
    }

    private var tint: Color {
        switch status.mode {
        case .sixDOF:
            return status.quality >= 0.7 ? Theme.accent : Theme.warning
        case .threeDOF:
            return Theme.warning
        case .off:
            return Theme.textTertiary
        }
    }
}
