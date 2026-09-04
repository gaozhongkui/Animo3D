//
//  HomeView.swift
//  Animo3D
//
//  "Create" Tab: Content launchpad.
//  Feature Dance Studio + Recommended Characters / Trending Dances (horizontal scroll, one-tap to enter studio) + more features.
//

import SwiftUI

enum HomeDest: Int, Identifiable {
    case studio, video, tripo
    var id: Int { rawValue }
}

/// A single studio launch configuration (pre-selectable character/dance).
struct StudioLaunch: Identifiable {
    let id = UUID()
    var character: String? = nil
    var dance: String? = nil
}

/// The showcase model for the trend cards. It ships in the bundle, so those cards render and dance
/// on a cold, offline launch instead of sitting on a spinner.
///
/// A file-scope constant rather than a member of HomeView: referencing a property of `self` from
/// inside that (very large) body crashes the Swift 6.2 type checker while solving the result
/// builder. A plain global needs no capture and sidesteps it.
private let builtInShowcaseModel: String = characterModelFile(BuiltInAssets.characterId)

struct HomeView: View {
    @ObservedObject private var remoteAssets = RemoteAssets.shared
    @State private var launch: StudioLaunch?
    @State private var showVideo = false

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    // The two carousels are their own properties, not inlined in `body`: the whole screen in one
    // result builder is more than the Swift 6.2 type checker can solve (it crashes outright once a
    // non-literal is referenced inside them).
    private var charactersSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Recommended Characters") {
                // Send notification to switch to Characters Tab
                NotificationCenter.default.post(name: NSNotification.Name("SwitchToCharactersTab"), object: nil)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(remoteAssets.characters.enumerated()), id: \.element.id) { i, c in
                        Button { launch = StudioLaunch(character: c.id) } label: {
                            posterCard(title: c.name, subtitle: "Ready to Dance") {
                                CharacterThumbView(characterKey: c.id, tint: tints[i % tints.count])
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var dancesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Trending Dances") {
                launch = StudioLaunch()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(remoteAssets.dances.prefix(12).enumerated()), id: \.element.id) { i, d in
                        Button { launch = StudioLaunch(dance: d.id) } label: {
                            posterCard(title: d.name, subtitle: "Hot Trend") {
                                if i == 0 {
                                    CardBackdrop(style: 0)
                                        .overlay(LiveDanceView(model: builtInShowcaseModel, dance: d.id))
                                } else {
                                    DanceThumbView(model: builtInShowcaseModel, dance: d.id, style: i)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    // Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hello, Creator")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("Bring your 3D characters to life in the real world")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Headline: large banner
                    Button {
                        HapticManager.medium()
                        launch = StudioLaunch()
                    } label: { heroCard }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, x: 0, y: 8)

                    charactersSection

                    dancesSection

                    // More ways to play
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Discover More")
                        VStack(spacing: 12) {
                            Button { showVideo = true } label: {
                                actionCard(icon: "video.fill", title: "Video Drive Motion", subtitle: "Upload video to mimic motions in real-time", color: .blue)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.large)
            .fullScreenCover(item: $launch) { l in
                studioCover(DanceStudioView(initialCharacter: l.character, initialDance: l.dance))
            }
            .fullScreenCover(isPresented: $showVideo) {
                studioCover(VideoDriveView())
            }
        }
    }

    // MARK: - Elegant Components

    private var heroCard: some View {
        ZStack(alignment: .leading) {
            // Background decoration
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))

            // Glassy graphics
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 150, height: 150)
                .offset(x: 200, y: -40)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter Dance Studio")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Start your immersive AR journey")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        Text("Start Now")
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white)
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }

                Spacer()

                Image(systemName: "arkit")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.trailing, 10)
            }
            .padding(24)
        }
        .frame(minHeight: 160)
    }

    private func posterCard<Thumb: View>(title: String, subtitle: LocalizedStringKey, @ViewBuilder thumb: () -> Thumb) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                thumb()
                    .frame(width: 140, height: 180)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Decoration badge
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private func actionCard(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.03), radius: 5, x: 0, y: 2)
    }

    private func sectionHeader(_ t: LocalizedStringKey, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(t)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            if let action = action {
                Button(action: action) {
                    Text("All")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal)
    }


    /// Fullscreen studio container (includes close button)
    private func studioCover<V: View>(_ content: V) -> some View {
        NavigationStack {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { launch = nil; showVideo = false } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}
