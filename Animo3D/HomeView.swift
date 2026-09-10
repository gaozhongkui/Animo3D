//
//  HomeView.swift
//  Animo3D
//
//  "Create" Tab: Content launchpad.
//  Hero studio banner + Featured Dancers (2x2 grid) / Trending Dances (horizontal scroll), one tap
//  into the studio from either, then the secondary entry points.
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

    /// One gutter for the whole page, matching the inset of the large navigation title.
    ///
    /// The sections used to mix `.padding(.horizontal)` (16) with a hand-written 20, so the left
    /// edge of the screen stepped in and out as you scrolled past each heading - and the headings
    /// that did use 20 sat visibly proud of "Create" above them.
    private let gutter: CGFloat = 16

    // The carousels and banners are their own properties, not inlined in `body`: the whole screen in
    // one result builder is more than the Swift 6.2 type checker can solve (it crashes outright once
    // a non-literal is referenced inside them).
    private var charactersSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Featured Dancers") {
                AppRouter.shared.openCharacters(.mine)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)], spacing: 20) {
                ForEach(Array(remoteAssets.characters.prefix(4).enumerated()), id: \.element.id) { i, c in
                    Button {
                        HapticManager.light()
                        launch = StudioLaunch(character: c.id)
                        Track.log(.characterSelected, ["character": c.id, "source": "home_grid"])
                    } label: {
                        CharacterCard(name: c.name, characterKey: c.id, tint: tints[i % tints.count])
                    }
                    .buttonStyle(CardButtonStyle())
                }
            }
            .padding(.horizontal, gutter)
        }
    }

    private var dancesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Trending Dances") {
                launch = StudioLaunch()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(remoteAssets.dances.prefix(8).enumerated()), id: \.element.id) { i, d in
                        Button {
                            launch = StudioLaunch(dance: d.id)
                            Track.log(.danceSelected, ["dance": d.id, "source": "home_carousel"])
                        } label: {
                            posterCard(title: d.name) {
                                if i == 0 {
                                    CardBackdrop(style: 0)
                                        .overlay(LiveDanceView(character: showcaseCharacter, dance: d.id))
                                } else {
                                    DanceCardView(character: showcaseCharacter, dance: d.id, style: i)
                                }
                            }
                        }.buttonStyle(CardButtonStyle())
                    }
                }
                .padding(.horizontal, gutter)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // The strapline only. The greeting that used to sit here was a second 28pt
                    // heading directly under the large "Create" title - two titles, one screen.
                    Text("Bring your 3D characters to life in the real world")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, gutter)

                    // Headline: large banner
                    Button {
                        HapticManager.medium()
                        launch = StudioLaunch()
                        Track.log(.studioStep, ["step": "start", "source": "home_hero"])
                    } label: { heroCard }
                        .buttonStyle(CardButtonStyle())
                        .padding(.horizontal, gutter)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, x: 0, y: 8)

                    charactersSection

                    dancesSection

                    // More ways to play
                    VStack(alignment: .leading, spacing: 14) {
                        sectionHeader("More Ways to Play")
                        VStack(spacing: 12) {
                            Button {
                                showVideo = true
                                Track.log(.videoDriveStarted)
                            } label: {
                                actionCard(icon: "video.fill",
                                           title: "Video Drive Motion",
                                           subtitle: "Upload video to mimic motions in real-time",
                                           iconFill: Color.blue)
                            }.buttonStyle(CardButtonStyle())

                            // The doorway to the Sketchfab library, in the same list as the other
                            // secondary entry points rather than as a gradient slab mid-page.
                            Button {
                                AppRouter.shared.openCharacters(.community)
                            } label: {
                                actionCard(icon: "globe.americas.fill",
                                           title: "Browse the Community",
                                           subtitle: "Thousands of shared 3D models, ready to view in AR",
                                           iconFill: communityGradient)
                            }.buttonStyle(CardButtonStyle())
                        }
                        .padding(.horizontal, gutter)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 24)
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Start New AR Show")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("Bring 3D characters into your world and direct your own immersive performance.")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Clear of the glyph, and nothing else. The copy used to be capped at a flat 260pt so
            // it would not collide with an icon sitting next to it in an HStack - which truncated
            // the subtitle mid-word ("...direct your own imm...") on every phone made.
            .padding(.trailing, 56)

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
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
        .background(heroBackdrop)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Decoration only: both the glow and the glyph are behind the copy, anchored to the card's own
    /// corners, so neither steals width from the text on a narrow phone.
    private var heroBackdrop: some View {
        LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 160, height: 160)
                    .offset(x: 48, y: -56)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arkit")
                    .font(.system(size: 58))
                    .foregroundStyle(.white.opacity(0.16))
                    .padding([.trailing, .bottom], 18)
            }
    }

    /// A dance tile. 3:4 like the character cards, so the two carousels share a rhythm.
    ///
    /// It carried a subtitle that read "Hot Trend" on every single card - a second line of type
    /// that told the user nothing. The section heading already says what these are.
    private func posterCard<Thumb: View>(title: String, @ViewBuilder thumb: () -> Thumb) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                thumb()
                    .frame(width: 140, height: 186)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // Decoration badge
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(8)
            }
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

            // Fixed width, one line: a long dance name used to stretch its own tile wider than the
            // rest and knock the row out of step.
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    /// The brand indigo/violet, the same pair the paywall and the app icon use.
    private var communityGradient: LinearGradient {
        LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// `iconFill` is any `ShapeStyle`, not a `Color`, so a row can carry a gradient tile.
    private func actionCard<Fill: ShapeStyle>(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, iconFill: Fill) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(iconFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.horizontal, gutter)
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
