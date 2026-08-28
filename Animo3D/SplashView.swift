//
//  SplashView.swift
//  Animo3D
//
//  Splash screen: Shows brand Logo animation.
//

import SwiftUI

struct SplashView: View {
    @Binding var isActive: Bool
    @State private var scale = 0.7
    @State private var opacity = 0.4

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Logo icon
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 120, height: 120)
                        .blur(radius: 20)
                        .opacity(0.3)

                    Image(systemName: "sparkles")
                        .font(.system(size: 80, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(scale)
                .opacity(opacity)

                // App name
                VStack(spacing: 8) {
                    Text("Livo 3D")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .tracking(2)

                    Text("Fill your space with dance")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .kerning(4)
                }
                .offset(y: 20)
                .opacity(opacity)
            }
        }
        .onAppear {
            // Warm up heavy assets (like Catalog), using splash time for IO
            Task(priority: .userInitiated) {
                _ = Catalog.shared
            }

            withAnimation(.easeIn(duration: 1.2)) {
                self.scale = 1.0
                self.opacity = 1.0
            }

            // Switch to main interface after 2.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.isActive = true
                }
            }
        }
    }
}

#Preview {
    SplashView(isActive: .constant(false))
}
