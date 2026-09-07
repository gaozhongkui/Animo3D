//
//  StageLoadingHUD.swift
//  Animo3D
//
//  The mask shown while a stage is being assembled. Lifted out of DanceStudioView, which had grown
//  to hold the performer, the whole three-step wizard, three grids and this.
//
//  It has two states, and the difference matters to the user: a download has a real percentage and
//  an unknown wait, while a local asset only has to be parsed and mounted. Reporting "downloading"
//  for the built-in character - which is what happened while every asset URL in the shipped index
//  was a placeholder - reads as a broken network rather than a busy device.
//

import SwiftUI

struct StageLoadingHUD: View {
    /// Download progress of the slowest asset in flight, or nil when nothing is downloading.
    let progress: Double?

    @State private var spinning = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            // Soft colour wash behind the spinner.
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .blur(radius: 50)
                    .offset(x: -100, y: -150)

                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 300, height: 300)
                    .blur(radius: 50)
                    .offset(x: 100, y: 150)
            }

            VStack(spacing: 28) {
                spinner
                VStack(spacing: 12) {
                    if let progress {
                        downloadState(progress)
                    } else {
                        preparingState
                    }
                }
            }
        }
        .onAppear { spinning = true }
        .transition(.opacity.combined(with: .scale(scale: 1.1)))
    }

    private var spinner: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 4)
                .frame(width: 80, height: 80)

            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(
                    LinearGradient(colors: [Color.accentColor, .purple], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)

            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Color.accentColor, .white], startPoint: .top, endPoint: .bottom))
        }
    }

    private func downloadState(_ p: Double) -> some View {
        Group {
            Text("Downloading Assets")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .tracking(1)

            ProgressView(value: p)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .frame(width: 200)
                .scaleEffect(x: 1, y: 1.5, anchor: .center)

            Text("\(Int(p * 100))%")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var preparingState: some View {
        Group {
            Text("Preparing Stage")
                .font(.system(size: 20, weight: .black, design: .rounded))
                .tracking(1)

            Text("Optimizing 3D Render Engine...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
