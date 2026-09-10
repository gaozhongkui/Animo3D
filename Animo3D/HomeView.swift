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

/// The showcase character for the trend cards: the built-in one, so the live card needs no
/// download. Read through a function rather than stored, because the built-in id now comes from the
/// index rather than a compile-time constant.
private var showcaseCharacter: String { BuiltInAssets.characterId }

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
                        Button {
                            launch = StudioLaunch(character: c.id)
                            Track.log(.characterSelected, ["character": c.id, "source": "home_carousel"])
                        } label: {
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
                        Button {
                            launch = StudioLaunch(dance: d.id)
                            Track.log(.danceSelected, ["dance": d.id, "source": "home_carousel"])
                        } label: {
                            posterCard(title: d.name, subtitle: "Hot Trend") {
                                if i == 0 {
                                    CardBackdrop(style: 0)
                                        .overlay(LiveDanceView(character: showcaseCharacter, dance: d.id))
                                } else {
                                    DanceCardView(character: showcaseCharacter, dance: d.id, style: i)
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
                        Track.log(.studioStep, ["step": "start", "source": "home_hero"])
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
                            Button {
                                showVideo = true
                                Track.log(.videoDriveStarted)
                            } label: {
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
            .trackScreen("Home")
            .fullScreenCover(item: $launch) { l in
                studioCover(DanceStudioView(initialCharacter: l.character, initialDance: l.dance))
            }
            .fullScreenCover(isPresented: $showVideo) {
                studioCover(VideoDriveView())
            }
            // index.json is the only source for both carousels, so until it lands there is nothing
            // to show. On a normal launch the splash holds until it arrives, so this is really the
            // failure state - the one that needs a retry the user can press.
            .overlay { if remoteAssets.characters.isEmpty { catalogWait } }
        }
    }

    /// Shown when the home screen has nothing to draw: the catalog is late, or unreachable.
    ///
    /// The splash covers the normal wait, so by the time anyone sees this something is wrong and the
    /// screen's job is to say so and offer a way out. It used to be a system `ProgressView` on flat
    /// `systemGroupedBackground` - a grey screen with a spinner, in an app that is otherwise a dark
    /// neon stage, and shown *after* the splash had already made the user wait.
    private var catalogWait: some View {
        ZStack {
            BrandLoading.ground

            VStack(spacing: 14) {
                Image(systemName: remoteAssets.state == .unavailable
                      ? "wifi.exclamationmark" : "sparkles")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.bottom, 6)

                if remoteAssets.state == .unavailable {
                    Text("Can't reach the studio")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Check your connection. This keeps trying on its own.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                    Button {
                        HapticManager.light()
                        remoteAssets.retry()
                    } label: {
                        Text("Try Again")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 26).padding(.vertical, 11)
                            .background(Capsule().fill(.white))
                    }
                    .padding(.top, 8)
                } else {
                    Text("Loading your studio")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    BrandShimmerBar().padding(.top, 4)
                }
            }
            .padding(36)
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

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Start New AR Show")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text("Bring 3D characters into your world and direct your own immersive performance.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The text container now takes up ~70% of the horizontal space, giving the
                    // messaging more room to breathe before being interrupted by the icon.
                    .frame(maxWidth: 260, alignment: .leading)

                    HStack(spacing: 8) {
                        Text("Start Now")
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.white)
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                }

                Spacer()

                Image(systemName: "arkit")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.15))
                    .padding(.trailing, 8)
            }
            .padding(26)
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
