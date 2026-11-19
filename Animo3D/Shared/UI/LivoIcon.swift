//
//  LivoIcon.swift
//  Livo 3D
//
//  SwiftUI-based app icon design.
//  It can be used as the blueprint for producing the final app icon.
//

import SwiftUI

struct LivoIcon: View {
    var body: some View {
        ZStack {
            // Background gradient: a diffuse deep indigo-to-purple blend
            LinearGradient(
                colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Decorative element: flowing light
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 40)
                .offset(x: 100, y: -120)

            VStack(spacing: -10) {
                // Core symbol: a shining star, standing for AR and inspiration
                Image(systemName: "sparkles")
                    .font(.system(size: 140, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 5)

                // The letter "L", standing for Livo
                Text("L")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(x: -40, y: -20)
            }
        }
        .frame(width: 512, height: 512) // Standard icon size
        .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
    }
}

#Preview {
    LivoIcon()
        .scaleEffect(0.5)
}
