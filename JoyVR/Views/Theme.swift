//
//  Theme.swift
//  JoyVR
//

import SwiftUI

enum Theme {
    static let background = Color(red: 0.047, green: 0.059, blue: 0.078)
    static let card = Color(red: 0.082, green: 0.102, blue: 0.129)
    static let cardRaised = Color(red: 0.110, green: 0.133, blue: 0.165)
    static let accent = Color(red: 0.310, green: 0.890, blue: 0.757)
    static let textSecondary = Color(white: 0.62)
    static let textTertiary = Color(white: 0.44)
    static let stroke = Color.white.opacity(0.07)
    static let warning = Color(red: 0.95, green: 0.62, blue: 0.30)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.35)))
            )
            .foregroundStyle(Color.black.opacity(0.85))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.cardRaised.opacity(configuration.isPressed ? 0.7 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.stroke, lineWidth: 1)
            )
            .foregroundStyle(.white.opacity(0.92))
    }
}

struct StatusDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .fill(isOn ? Theme.accent : Theme.warning)
            .frame(width: 8, height: 8)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
    }
}
