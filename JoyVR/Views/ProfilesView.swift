//
//  ProfilesView.swift
//  JoyVR
//
//  Named setups for a VR box, plus the comfort settings for the game you are
//  playing. Applying one takes a tap.
//

import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingSave = false
    @State private var newName = ""
    @State private var newGame = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle(text: "Saved profiles")

                    if model.profiles.isEmpty {
                        emptyCard
                    } else {
                        ForEach(model.profiles) { profile in
                            profileRow(profile)
                        }
                    }

                    Button("Save current setup") {
                        newName = ""
                        newGame = ""
                        showingSave = true
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if let active = model.activeProfile {
                        Button("Update \(active.name) with these settings") {
                            model.updateActiveProfile()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    SectionTitle(text: "Comfort")
                        .padding(.top, 4)

                    comfortCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showingSave) {
            saveSheet
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Profiles")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("One tap per headset, one per game")
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
        .padding(.bottom, 6)
    }

    // MARK: Profiles

    private var emptyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("No profiles yet")
                    .font(.headline)
                Text("Set the picture and comfort controls to suit a box, then save them with a name. Switch boxes by tapping its profile.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func profileRow(_ profile: VRProfile) -> some View {
        let isActive = profile.id == model.activeProfileID

        return HStack(spacing: 10) {
            Button {
                model.applyProfile(profile)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.subheadline.weight(.semibold))
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(profile.game.isEmpty ? "Any game" : "for \(profile.game)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(profile.quality.title) · \(profile.summary)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                model.deleteProfile(profile)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.cardRaised))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isActive ? Theme.accent.opacity(0.10) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1)
        )
    }

    // MARK: Comfort

    private var comfortCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Supersampling")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.2f×", model.settings.supersampling))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    Slider(value: $model.settings.supersampling, in: 0.6...2.0, step: 0.05)
                        .tint(Theme.accent)
                    Text("Renders more pixels than the screen on the PC, for a sharper picture.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                Divider().overlay(Theme.stroke)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Refresh rate")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Refresh rate", selection: $model.settings.refreshRate) {
                        ForEach([60, 90, 120], id: \.self) { rate in
                            Text("\(rate) Hz").tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Divider().overlay(Theme.stroke)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("FOV crop")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(Int((model.settings.fovCrop * 100).rounded()))%")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    Slider(value: $model.settings.fovCrop, in: 0...0.4, step: 0.01)
                        .tint(Theme.accent)
                    Text("Narrows the rendered field of view, so less moves at the edges of your vision.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(Theme.stroke)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Vignette")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(Int((model.settings.vignette * 100).rounded()))%")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    Slider(value: $model.settings.vignette, in: 0...1, step: 0.05)
                        .tint(Theme.accent)
                    Text("Darkens the edges of the picture for motion sickness.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                Text("Comfort settings are saved with the profile and sent to the PC, which applies the projection, refresh and render scale. The vignette is drawn on the phone.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Save sheet

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save this setup")
                .font(.title3.weight(.semibold))

            TextField("Living room box", text: $newName)
                .textInputAutocapitalization(.words)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardRaised))

            TextField("Game (optional)", text: $newGame)
                .textInputAutocapitalization(.words)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.cardRaised))

            Text("Name it after the box. Add a game if this comfort setup is just for one.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Button("Save") {
                if model.saveProfile(name: newName, game: newGame) != nil {
                    showingSave = false
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.ignoresSafeArea())
        .presentationDetents([.height(330)])
    }
}
