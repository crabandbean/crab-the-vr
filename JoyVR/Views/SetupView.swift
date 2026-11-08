//
//  SetupView.swift
//  JoyVR
//
//  The half of JoyVR that lives on the PC. Written out here so nobody has to
//  guess how the two ends meet.
//

import SwiftUI

struct SetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Your PC")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Crab the VR needs a small companion program on the PC. SteamVR talks to it, and it talks to this app.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                stepCard(
                    number: "1",
                    title: "Copy the PC folder to your PC",
                    body: "The project ships a folder called PC. Copy it to your Windows machine — it holds the SteamVR driver, the protocol spec and a test stream tool. The same folder is in the iPhone's Files app under On My iPhone › Crab the VR › UserProjects › JoyVR › PC: select it, tap Compress, then email or save the zip to iCloud Drive to open on your PC.",
                    code: nil
                )

                stepCard(
                    number: "2",
                    title: "Run the one-click setup",
                    body: "In the PC folder, double-click Setup Crab the VR.cmd. It installs the free C++ build tools if they are missing, builds the driver and copies it into SteamVR. The first run is a big download.",
                    code: "Setup Crab the VR.cmd"
                )

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start SteamVR")
                            .font(.subheadline.weight(.semibold))
                        Text("Restart SteamVR after setup. It will list a headset called Crab the VR. The manual build commands are in PC/README.md if you prefer them.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                stepCard(
                    number: "3",
                    title: "Same Wi-Fi, then connect",
                    body: "Put the PC and the iPhone on the same network, open the Link tab, tap Find my PC and pick it. If discovery is blocked by your router, type the PC's address instead.",
                    code: nil
                )

                SectionTitle(text: "Checking the phone alone")
                    .padding(.top, 4)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Test stream tool")
                            .font(.subheadline.weight(.semibold))
                        Text("No driver built yet? The PC folder includes a Python tool that answers discovery and streams a test image to the phone, so you can check picture and tracking first.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("python tools/test_stream.py --width 2560 --height 1280")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SectionTitle(text: "If it does not connect")
                    .padding(.top, 4)

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        bullet("Allow Crab the VR on the Local Network when iOS asks — without it the phone cannot see the PC.")
                        bullet("Allow the PC app through Windows Firewall on UDP ports 8930 and 8931.")
                        bullet("Use 5 GHz Wi-Fi and stay in the same room as the router. A phone box on 2.4 GHz will stutter.")
                        bullet("Turn off a VPN on either device while you link them.")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.background.ignoresSafeArea())
    }

    private func stepCard(number: String, title: String, body: String, code: String?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(number)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.accent.opacity(0.18)))
                        .foregroundStyle(Theme.accent)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(body)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let code {
                    Text(code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardRaised))
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Theme.textTertiary)
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
