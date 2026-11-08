//
//  HandSkeletonOverlay.swift
//  JoyVR
//
//  A small picture of what the camera sees: one skeleton per hand, drawn from
//  the same joints that are on their way to the PC.
//

import SwiftUI
import simd

struct HandSkeletonOverlay: View {
    let hands: [HandTracker.OverlayHand]

    private static let bones: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (0, 9), (9, 10), (10, 11), (11, 12),
        (0, 13), (13, 14), (14, 15), (15, 16),
        (0, 17), (17, 18), (18, 19), (19, 20),
        (5, 9), (9, 13), (13, 17)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "hand.point.up.left.fill")
                Text("Hands")
                Spacer(minLength: 8)
                Text("\(visibleCount)")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.25))

                if hands.isEmpty {
                    Text("No hands in view")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }

                Canvas { context, size in
                    for hand in hands {
                        let color: Color = hand.chirality == .left
                            ? Theme.accent
                            : Color(red: 0.55, green: 0.75, blue: 1.0)

                        for (from, to) in Self.bones {
                            guard hand.joints.indices.contains(from),
                                  hand.joints.indices.contains(to) else { continue }
                            var path = Path()
                            path.move(to: point(hand.joints[from], in: size))
                            path.addLine(to: point(hand.joints[to], in: size))
                            context.stroke(path,
                                           with: .color(color.opacity(hand.opacity * 0.9)),
                                           lineWidth: 1.5)
                        }

                        for joint in hand.joints {
                            let position = point(joint, in: size)
                            let rect = CGRect(x: position.x - 1.5,
                                              y: position.y - 1.5,
                                              width: 3,
                                              height: 3)
                            context.fill(Path(ellipseIn: rect),
                                         with: .color(color.opacity(hand.opacity * 0.8)))
                        }
                    }
                }
            }
            .frame(width: 150, height: 104)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .opacity(hands.isEmpty ? 0.55 : 1)
    }

    private var visibleCount: Int {
        hands.filter { $0.opacity > 0.1 }.count
    }

    /// Vision counts from the bottom left, so the picture is mirrored like a
    /// selfie and flipped into the screen's coordinates.
    private func point(_ normalized: SIMD2<Float>, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(1 - normalized.x) * size.width,
                y: CGFloat(1 - normalized.y) * size.height)
    }
}
