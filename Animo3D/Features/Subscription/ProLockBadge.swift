import SwiftUI

/// Kept separate from preview content so locked items remain visible and recognizable.
struct ProLockBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: "PRO")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [Color(rgb: 0x7555E8), Color(rgb: 0xA16AF0)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Requires Pro")
        .allowsHitTesting(false)
    }
}
