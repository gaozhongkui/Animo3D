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
    // 异步 3D 延迟加载状态，用于彻底粉碎冷启动主线程卡顿
    @State private var is3DViewRendered = false


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
                if remoteAssets.characters.isEmpty {
                    // 数据未就绪时展现高级骨架流光屏
                    ForEach(0..<4, id: \.self) { i in
                        skeletonCard(aspectRatio: 3.0 / 4.0)
                    }
                } else {
                    ForEach(Array(remoteAssets.characters.prefix(4).enumerated()), id: \.element.id) { i, c in
                        Button {
                            HapticManager.light()
                            launch = StudioLaunch(character: c.id)
                            Track.log(.characterSelected, ["character": c.id, "source": "home_grid"])
                        } label: {
                            CharacterCard(name: c.name, characterKey: c.id, style: i)
                        }
                        .buttonStyle(CardButtonStyle())
                    }
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
                    if remoteAssets.dances.isEmpty {
                        // 推荐栏骨架屏横滑插值
                        ForEach(0..<5, id: \.self) { _ in
                            skeletonCard(width: 140, height: 186)
                        }
                    } else {
                        ForEach(Array(remoteAssets.dances.prefix(8).enumerated()), id: \.element.id) { i, d in
                            Button {
                                launch = StudioLaunch(dance: d.id)
                                Track.log(.danceSelected, ["dance": d.id, "source": "home_carousel"])
                            } label: {
                                posterCard(title: d.name) {
                                    if i == 0 && is3DViewRendered {
                                        CardBackdrop(style: 0)
                                            .overlay(LiveDanceView(character: showcaseCharacter, dance: d.id,
                                                                   accent: CardBackdrop.accent(for: 0)))
                                    } else {
                                        DanceCardView(character: showcaseCharacter, dance: d.id, style: i)
                                    }
                                }
                            }.buttonStyle(CardButtonStyle())
                        }
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
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                            GridItem(.flexible(), spacing: 14)], spacing: 14) {
                            Button {
                                showVideo = true
                                Track.log(.videoDriveStarted)
                            } label: {
                                gridActionCard(icon: "video.fill",
                                               title: "Video Drive",
                                               subtitle: "Upload video to mimic motions in real-time",
                                               iconFill: Color.blue)
                            }.buttonStyle(CardButtonStyle())

                            Button {
                                AppRouter.shared.openCharacters(.community)
                            } label: {
                                gridActionCard(icon: "globe.americas.fill",
                                               title: "Community",
                                               subtitle: "Thousands of shared 3D models ready for AR",
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
            // 骨架屏秒开优化：正常网络流加载时绝不采用大黑块弹窗强行中断创作者体验，唯有在网络死锁完全不可用(.unavailable)时才启动阻断异常提示层
            .overlay { if remoteAssets.state == .unavailable && remoteAssets.characters.isEmpty { catalogWait } }
            .onAppear {
                // 延迟一小段安全转场时间（0.35秒），确保闪屏页面淡出与路由切换动画完全平滑渲染完毕后，再激活 3D 引擎。
                // 这样能将闪屏到主页的 CPU 瞬间吞吐卡顿彻底降为 0，带来丝滑顺畅的德芙般转场。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeIn(duration: 0.35)) {
                        is3DViewRendered = true
                    }
                }
            }
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
        ZStack(alignment: .trailing) {
            // Right Side: 3D Stage Window Window Showcase (免下载，免配置的冷启动实时 3D 舞台渲染)
            if !remoteAssets.dances.isEmpty && is3DViewRendered {
                CardBackdrop(style: 1)
                    .frame(width: 160, height: 200)
                    .overlay {
                        LiveDanceView(character: showcaseCharacter,
                                      dance: remoteAssets.dances.first?.id ?? "",
                                      accent: CardBackdrop.accent(for: 1))
                            .scaleEffect(1.15)
                            .offset(y: 10)
                    }
                    .mask(
                        LinearGradient(colors: [.black, .black, .black, .clear],
                                       startPoint: .trailing, endPoint: .leading)
                    )
                    .opacity(0.85)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // Left Side: Content copy & call to actions
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start New AR Show")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("Bring 3D characters into your world and direct your own immersive performance.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.trailing, 130) // Prevent text colliding with the 3D dancer window

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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .background(heroBackdrop)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    /// Decoration only: multi-layered digital futuristic fluid glows and mesh gradient shapes.
    private var heroBackdrop: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor, Color(rgb: 0x4F46E5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            Circle()
                .fill(Color(rgb: 0xEC4899).opacity(0.4))
                .frame(width: 200, height: 200)
                .blur(radius: 40)
                .offset(x: 120, y: -40)

            Circle()
                .fill(Color(rgb: 0x06B6D4).opacity(0.3))
                .frame(width: 150, height: 150)
                .blur(radius: 30)
                .offset(x: -80, y: 60)

            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 1)
                .frame(width: 240, height: 240)
                .offset(x: 80, y: -60)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arkit")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.16))
                .padding([.trailing, .bottom], 16)
        }
    }

    private func gridActionCard<Fill: ShapeStyle>(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey, iconFill: Fill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(iconFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
                Image(systemName: "arrow.up.forward.circle.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.02), radius: 5, x: 0, y: 2)
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
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, gutter)
    }

    /// 高级毛玻璃流光数字骨架屏组件 (Glassmorphism Shimmer Skeleton)
    @ViewBuilder
    private func skeletonCard(width: CGFloat? = nil, height: CGFloat? = nil, aspectRatio: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let ratio = aspectRatio {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(ratio, contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: width, height: height)
                }
            }
            .overlay {
                LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.08), Color.white.opacity(0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .rotationEffect(.degrees(30))
            }
            .overlay {
                // 呼吸灯光感反馈，平滑削减冷启动尴尬
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
            }

            // 骨架屏伪文字线
            Capsule()
                .fill(Color(.label).opacity(0.04))
                .frame(width: width != nil ? width! * 0.7 : 90, height: 14)
                .padding(.leading, 4)
        }
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
