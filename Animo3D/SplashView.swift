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
    @State private var titleIn = false
    @State private var subtitleIn = false
    @State private var showHint = false
    @State private var bgOffset = CGSize.zero
    @State private var logoPulse = false

    var body: some View {
        ZStack {
            // 动态背景：让光圈缓慢漂移
            dynamicGround

            VStack(spacing: 22) {
                mark
                VStack(spacing: 8) {
                    wordmark
                    subtitle
                }
                hint
                    .frame(height: 28)
            }
        }
        .task { await hold() }
        .onAppear {
            appeared = Date()

            // 编排式入场动画
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                logoIn = true
            }

            withAnimation(.easeOut(duration: 0.6).delay(0.3)) {
                titleIn = true
            }

            withAnimation(.easeOut(duration: 0.6).delay(0.5)) {
                subtitleIn = true
            }

            // 背景呼吸动画
            withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                bgOffset = CGSize(width: 20, height: 15)
            }

            // 启动 Logo 呼吸效果
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                logoPulse = true
            }
        }
    }

    private var dynamicGround: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.06, blue: 0.20),
                                    Color(red: 0.03, green: 0.02, blue: 0.07)],
                           startPoint: .top, endPoint: .bottom)

            Circle().fill(BrandLoading.cyan.opacity(0.18))
                .frame(width: 320, height: 320).blur(radius: 90)
                .offset(x: -90 + bgOffset.width, y: -170 + bgOffset.height)

            Circle().fill(BrandLoading.pink.opacity(0.16))
                .frame(width: 300, height: 300).blur(radius: 90)
                .offset(x: 110 - bgOffset.width, y: 150 - bgOffset.height)
        }
        .ignoresSafeArea()
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
                .scaleEffect(logoPulse ? 1.05 : 1.0) // 呼吸缩放
                .opacity(logoPulse ? 1.0 : 0.85)    // 呼吸透明度
        }
        .scaleEffect(logoIn ? 1 : 0.7)
        .opacity(logoIn ? 1 : 0)
    }

    private var wordmark: some View {
        Text("Livo 3D")
            .font(.system(size: 44, weight: .black, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white)
            .offset(y: titleIn ? 0 : 10)
            .opacity(titleIn ? 1 : 0)
    }

    private var subtitle: some View {
        Text("Fill your space with dance")
            .font(.system(size: 14, weight: .medium))
            .kerning(3)
            .foregroundStyle(.white.opacity(0.62))
            .offset(y: subtitleIn ? 0 : 8)
            .opacity(subtitleIn ? 1 : 0)
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
