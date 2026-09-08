//
//  SharedUI.swift
//  Animo3D
//
//  The app-wide circular back/close button, which keeps every page consistent.
//

import SwiftUI

struct CircleButton: View {
    let system: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }
}

/// The app's loading vocabulary, shared by the splash and the stage HUD so the two do not drift.
///
/// Both used to invent their own: the splash a scaling logo on the system background, the stage a
/// rotating trimmed circle on full-screen `.ultraThinMaterial`. Neither looked like the other, and
/// the frosted one washed the stage out to grey behind it.
enum BrandLoading {
    static let cyan = Color(red: 0.43, green: 0.91, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.43, blue: 0.78)

    /// The ground everything loading sits on: the stage's own palette, never a system colour.
    static var ground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.06, blue: 0.20),
                                    Color(red: 0.03, green: 0.02, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)
            Circle().fill(cyan.opacity(0.18))
                .frame(width: 320, height: 320).blur(radius: 90)
                .offset(x: -90, y: -170)
            Circle().fill(pink.opacity(0.16))
                .frame(width: 300, height: 300).blur(radius: 90)
                .offset(x: 110, y: 150)
        }
        .ignoresSafeArea()
    }
}

/// A thin bar with a highlight travelling along it, for waits of unknown length.
///
/// Preferred over a spinner on a branded screen: a system `ProgressView` on top of the brand reads
/// as the brand having stalled, where a moving highlight reads as the brand still working.
struct BrandShimmerBar: View {
    var width: CGFloat = 160
    @State private var shift = false

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.12))
            Capsule()
                .fill(LinearGradient(colors: [.clear, BrandLoading.cyan, .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width * 0.44)
                .offset(x: shift ? width * 0.56 : -width * 0.56)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: shift)
        }
        .frame(width: width, height: 3)
        .clipShape(Capsule())
        .onAppear { shift = true }
    }
}
