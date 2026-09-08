//
//  StageLoadingHUD.swift
//  Animo3D
//
//  The mask over the stage while it is being assembled.
//
//  It has two states, and the difference matters: a download has a real percentage and an unknown
//  wait, while a local asset only has to be parsed and mounted. Reporting "downloading" for the
//  built-in character - which is what happened while every asset URL in the shipped index was a
//  placeholder - reads as a broken network rather than a busy device.
//
//  Two things about the look, both of which it got wrong before:
//
//  - The ground was full-screen `.ultraThinMaterial`. Frosted glass over a nearly black stage is
//    grey, so the app's most colourful screen was covered by its dullest. It uses the stage's own
//    palette now, from `BrandLoading`.
//  - It invented its own spinner - a rotating trimmed circle with a `sparkles` badge in the middle -
//    while the splash was doing something else entirely. Both now speak `BrandShimmerBar`.
//
//  The copy changed too. "Optimizing 3D Render Engine..." is a sentence written for the person who
//  built the renderer; nobody waiting to watch a character dance is reassured by it.
//

import SwiftUI

struct StageLoadingHUD: View {
    /// Download progress of the slowest asset in flight, or nil when nothing is downloading.
    let progress: Double?

    @State private var pulse = false

    var body: some View {
        ZStack {
            BrandLoading.ground

            VStack(spacing: 26) {
                mark
                VStack(spacing: 10) {
                    Text(progress == nil ? "Setting the stage" : "Getting the assets")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    if let progress {
                        percentBar(progress)
                    } else {
                        BrandShimmerBar()
                        Text("Lights, floor, and your dancer")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(40)
        }
        .transition(.opacity)
        .onAppear { pulse = true }
    }

    /// A soft breathing halo instead of a rotating ring: nothing here is measuring anything, so a
    /// dial that goes round and round claims more than it knows.
    private var mark: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [BrandLoading.cyan, .purple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 128, height: 128)
                .blur(radius: 30)
                .opacity(pulse ? 0.62 : 0.32)
                .scaleEffect(pulse ? 1.06 : 0.94)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulse)

            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.white, Color(red: 0.78, green: 0.90, blue: 1.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
        }
    }

    /// A real measurement gets a real bar, with the number beside it rather than under it - the
    /// value and the bar are the same fact, and splitting them across two lines read as two.
    private func percentBar(_ p: Double) -> some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule()
                        .fill(LinearGradient(colors: [BrandLoading.cyan, BrandLoading.pink],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * p))
                        .animation(.easeOut(duration: 0.25), value: p)
                }
            }
            .frame(width: 190, height: 5)

            Text(String(format: L("%d%%"), Int(p * 100)))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
    }
}
