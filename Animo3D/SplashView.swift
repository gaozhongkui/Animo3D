//
//  SplashView.swift
//  Animo3D
//
//  The launch screen, and the app's only loading state on a normal cold start.
//
//  It used to sit on a fixed 2.5s timer and then hand over to a home screen that showed its own
//  spinner while the catalog arrived - two waits in a row, the second one a system ProgressView on
//  flat grey. This holds here until the catalog is ready instead, so there is one loading moment,
//  it is on brand, and the home screen is already populated when it appears.
//
//  Three timings, and each one is there for a reason:
//    - a minimum, so a warm launch does not flash the brand for two frames
//    - a maximum, so a dead network cannot trap anyone on the splash; the home screen's own
//      unavailable state takes over past that, because it is the one with a retry button
//    - a delay before any progress hint appears, so a normal launch never looks like it is waiting
//

import SwiftUI

struct SplashView: View {
    @Binding var isActive: Bool
    @ObservedObject private var remoteAssets = RemoteAssets.shared

    /// Shortest time the brand stays up, so a fast launch is not a flicker.
    private let minimumHold: TimeInterval = 1.4
    /// Longest we wait for the catalog before handing over regardless.
    private let maximumHold: TimeInterval = 6.0
    /// How long before admitting we are waiting on something.
    private let hintAfter: TimeInterval = 1.8

    @State private var appeared = Date()
    @State private var logoIn = false
    @State private var showHint = false

    var body: some View {
        ZStack {
            // The app's own ground, shared with the stage HUD - not the system background, which
            // is white in light mode and made the launch look like a different app than the one
            // behind it.
            BrandLoading.ground

            VStack(spacing: 22) {
                mark
                wordmark
                hint
                    .frame(height: 28)          // reserved, so nothing shifts when it appears
            }
        }
        .task { await hold() }
        .onAppear {
            appeared = Date()
            withAnimation(.easeOut(duration: 0.8)) { logoIn = true }
        }
    }

    private var mark: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [BrandLoading.cyan, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
                .blur(radius: 34)
                .opacity(0.55)

            Image(systemName: "sparkles")
                .font(.system(size: 74, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(red: 0.75, green: 0.88, blue: 1.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
        .scaleEffect(logoIn ? 1 : 0.82)
        .opacity(logoIn ? 1 : 0)
    }

    private var wordmark: some View {
        VStack(spacing: 8) {
            Text("Livo 3D")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
            Text("Fill your space with dance")
                .font(.system(size: 14, weight: .medium))
                .kerning(3)
                .foregroundStyle(.white.opacity(0.62))
        }
        .opacity(logoIn ? 1 : 0)
    }

    @ViewBuilder
    private var hint: some View {
        if showHint { BrandShimmerBar().transition(.opacity) }
    }

    /// Wait for the catalog, bounded at both ends.
    private func hold() async {
        RemoteAssets.shared.start()          // idempotent; the app entry point also calls it

        let hintDeadline = Date().addingTimeInterval(hintAfter)
        let hardDeadline = Date().addingTimeInterval(maximumHold)
        let softDeadline = Date().addingTimeInterval(minimumHold)

        while !Task.isCancelled {
            let now = Date()
            if now >= hintDeadline, !showHint {
                withAnimation(.easeIn(duration: 0.3)) { showHint = true }
            }
            let ready = remoteAssets.state == .ready
            if now >= hardDeadline || (ready && now >= softDeadline) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        withAnimation(.easeInOut(duration: 0.45)) { isActive = true }
    }
}

#Preview {
    SplashView(isActive: .constant(false))
}
