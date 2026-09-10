//
//  RootTabView.swift
//  Animo3D
//
//  Main product structure: Home / Characters / Me three bottom tabs.
//

import SwiftUI
import Foundation
import Combine

/// Where the app is, as state the whole app can read and write.
///
/// Cross-tab jumps used to travel as `NSNotification`s, with the tab host relaying a second
/// notification down to the Characters screen to pick a segment. That drops requests: `onReceive`
/// only listens while its view is alive, and the relay fires in the same run loop turn as the tab
/// switch - before a Characters tab that has never been opened exists to hear it. So the first
/// "Community" tap of a session landed on My Characters. State has no such window.
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Int { case create = 0, characters = 1, me = 2 }
    enum CharactersSegment: Int { case mine = 0, community = 1 }

    @Published var tab: Tab = .create
    @Published var charactersSegment: CharactersSegment = .mine

    private init() {}

    /// Jump to the Characters tab, landing on a chosen segment.
    func openCharacters(_ segment: CharactersSegment) {
        charactersSegment = segment
        tab = .characters
    }
}

struct RootTabView: View {
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Create", systemImage: "sparkles") }
                .tag(AppRouter.Tab.create)
            CharactersView()
                .tabItem { Label("Characters", systemImage: "person.2.fill") }
                .tag(AppRouter.Tab.characters)
            ProfileView()
                .tabItem { Label("Me", systemImage: "person.fill") }
                .tag(AppRouter.Tab.me)
        }
        .onChange(of: router.tab) { _ in
            HapticManager.selection()
        }
        .accentColor(.accentColor)
    }
}

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var selectedModel: SketchfabModel?
    @State private var selectedCategory = "Trending"

    private let categories = ["Trending", "Characters", "Animals", "Buildings", "Vehicles", "Fantasy"]

    var body: some View {
        VStack(spacing: 0) {
            // Elegant search box
            VStack(spacing: 16) {
                // A button, not a field. Tapping it opens DiscoverSearchView, which owns the
                // query - so this grid always shows the category it says it is showing, and the
                // keyboard never covers results that a chip is still claiming to filter.
                // Same reasoning as the chips, plus one of its own: this opens a full-screen
                // cover, so a stray activation is the most disruptive thing on the page. The hit
                // area is pinned to the rounded rect below rather than the row it sits in.
                Button {
                    HapticManager.light()
                    showSearch = true
                    Track.log(.communitySearch)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            .font(.system(size: 14, weight: .bold))
                        Text("Search 3D Inspiration")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)

                // Category tags
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories, id: \.self) { cat in
                            // Selection is gated on how far the finger travelled, not on where it
                            // came up. `.onTapGesture` fires on touch-up wherever it lands, so a
                            // sideways flick kept switching category mid-swipe; a plain Button was
                            // better but still fired on quick flicks, because a scroll view only
                            // claims the gesture once it decides the drag is a scroll. Measuring
                            // the travel makes the rule explicit and leaves nothing to arbitrate:
                            // under 8pt is a tap, anything more is a scroll and selects nothing.
                            // `simultaneousGesture` so the row still scrolls normally underneath.
                            Text(LocalizedStringKey(cat))
                                .font(.system(size: 13, weight: selectedCategory == cat ? .bold : .medium))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(selectedCategory == cat ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(selectedCategory == cat ? .white : .primary.opacity(0.7))
                                // 44pt of height to aim at, while the capsule keeps its own size:
                                // the chip itself is about 29pt tall, under the minimum target, and
                                // a row of undersized targets is the other half of the mis-taps.
                                // Vertical only - growing them sideways would make neighbouring
                                // chips overlap, which trades one mis-tap for another.
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { v in
                                            guard abs(v.translation.width) < 8,
                                                  abs(v.translation.height) < 8 else { return }
                                            HapticManager.light()
                                            withAnimation(.spring(response: 0.3)) { selectedCategory = cat }
                                            Track.log(.communityCategory, ["category": cat])
                                        }
                                )
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)

            // searchText stays empty here for good: browsing is by category only now.
            DiscoverViewControllerRepresentable(searchText: $searchText, selectedCategory: $selectedCategory) { model in
                self.selectedModel = model
                Track.log(.communityModelOpened, ["model": model.name])
            }
        }
        .fullScreenCover(isPresented: $showSearch) { DiscoverSearchView() }
        .fullScreenCover(item: $selectedModel) { model in
            ModelDetailView(model: model)
                .overlay(alignment: .topLeading) {
                    CircleButton(system: "xmark") { selectedModel = nil }
                        .padding(.leading, 20).padding(.top, 10)
                }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}

struct ModelDetailView: View {
    let model: SketchfabModel
    @Environment(\.dismiss) private var dismiss
    @State private var show3DPreview = false
    /// The same embed, filling the screen. A separate presentation rather than an in-place resize:
    /// the preview lives inside the scroll view, and growing it there would push the page around and
    /// still leave it boxed in by the safe area.
    @State private var fullscreenPreview = false

    @State private var arLoading = false
    /// Bytes received, and the expected total when the server declares one. Kept as bytes rather
    /// than a fraction because Sketchfab's S3 redirect often sends no Content-Length, and a
    /// fraction of an unknown total can only ever be a guess.
    @State private var arReceived: Int64 = 0
    @State private var arTotal: Int64?
    @State private var arError: String?
    /// Set once the model is on disk, which presents the AR screen.
    @State private var arReady: ARModel?

    /// A downloaded model, ready to place. `Identifiable` so it can drive `fullScreenCover(item:)`.
    private struct ARModel: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    /// The Sketchfab embed with two of its viewer options set.
    ///
    /// `autostart=1` skips the poster-and-play-button step. The user has already said what they
    /// want by tapping the image, and a second tap on a play button to load the same thing is a
    /// step that only exists because the default embed is built for a web page it does not control.
    ///
    /// `ui_infos=0` removes the viewer's own name-and-author card from the top left, which sat
    /// directly under this page's close button and under the fullscreen title. Attribution is not
    /// lost: the Sketchfab watermark stays (`ui_watermark` is deliberately left alone), the page
    /// carries a SKETCHFAB badge, and Source Page links to the model on their site.
    ///
    /// Everything else is left at the author's settings - the camera framing included, which is why
    /// some models open smaller than the viewport and the fullscreen screen says to pinch.
    private var embedURL: URL? {
        guard var c = URLComponents(string: model.embedUrl) else { return nil }
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "autostart", value: "1"),
                                               URLQueryItem(name: "ui_infos", value: "0"),
                                               URLQueryItem(name: "ui_hint", value: "0")]
        return c.url
    }

    /// The small dark circular buttons that float over the preview. Two of them now, so the
    /// styling is in one place rather than copied.
    private func previewChip(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.6), in: Circle())
        }
    }

    /// How tall the model preview is.
    ///
    /// Proportional rather than the old fixed 400pt, because the two buttons that used to sit under
    /// the AR button are gone and the space they held should go to the thing people came to look
    /// at. Floored so a small phone does not end up with a letterbox, capped so a large one does
    /// not push the AR button off the bottom - the page has to keep fitting without scrolling.
    private var previewHeight: CGFloat {
        // Sized to the column, not to the screen. On an iPad the page is centred in a
        // `maxContentWidth` column, so measuring 62% of a 1366pt screen gave a preview far taller
        // than the thing it sits in is wide - a tall slot with a small model floating in it.
        let screen = UIScreen.main.bounds
        let column = min(screen.width, Self.maxContentWidth)
        return min(max(min(screen.height * 0.62, column * 1.25), 400), 580)
    }

    /// How wide the page is allowed to get.
    ///
    /// Everything here is a single column of reading material - title, author, stats, description,
    /// one action button. Left unbounded it runs the full width of an iPad: description lines get
    /// long enough to lose your place between them, and the AR button becomes a 976pt slab. A
    /// bounded, centred column is what the same content looks like on a phone, which is the layout
    /// it was designed for.
    static let maxContentWidth: CGFloat = 700

    private var arFraction: Double? {
        guard let total = arTotal, total > 0 else { return nil }
        return min(1, max(0, Double(arReceived) / Double(total)))
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Top main display area: Default static image, tap to open interactive 3D
                    ZStack(alignment: .bottom) {
                        if show3DPreview, let url = embedURL {
                            ZStack {
                                // The web view is transparent, so this placeholder covers the few
                                // seconds the embed needs to load instead of flashing a blank box.
                                Color(.secondarySystemBackground)
                                ProgressView()
                                WebView(url: url)
                            }
                                .frame(maxWidth: .infinity)
                                .frame(height: previewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    // Expand first, then back-to-image: the order matches how often
                                    // each is wanted. 400pt is enough to recognise a model and not
                                    // enough to inspect one, which is what the expand is for.
                                    HStack(spacing: 8) {
                                        previewChip("arrow.up.left.and.arrow.down.right") {
                                            fullscreenPreview = true
                                        }
                                        previewChip("photo.fill") { show3DPreview = false }
                                    }
                                    .padding(16)
                                }
                        } else {
                            // A scaled-to-fill image reports its own oversized width, which used to
                            // stretch the whole page far wider than the screen. Kept as an overlay on a
                            // fixed-size container, it can no longer influence layout.
                            Color(.secondarySystemBackground)
                                .frame(maxWidth: .infinity)
                                .frame(height: previewHeight)
                                .overlay {
                                    AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "cube.fill").font(.largeTitle).foregroundStyle(.tertiary)
                                    }
                                }
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { show3DPreview = true }

                            LinearGradient(colors: [.clear, .black.opacity(0.4)],
                                           startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .allowsHitTesting(false)

                            HStack(spacing: 8) {
                                Image(systemName: "move.3d").font(.title3.bold())
                                Text("Tap to Explore in 3D").font(.subheadline.bold())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .allowsHitTesting(false)   // The whole image is the tap target; the hint must not swallow it
                        }

                        if arLoading { DownloadOverlay(fraction: arFraction, received: arReceived) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 10)

                    // Details
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top) {
                                Text(model.name)
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(.blue)
                                    .font(.title2)
                                    .padding(.top, 4)
                            }

                            HStack(spacing: 16) {
                                statLabel(icon: "heart.fill", value: model.likeCount.formattedAbbreviated, color: .red)
                                statLabel(icon: "eye.fill", value: model.viewCount.formattedAbbreviated, color: .secondary)
                                Spacer()
                                Text("SKETCHFAB")
                                    .font(.system(size: 10, weight: .black))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color(.label).opacity(0.05), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()

                        // Core actions
                        VStack(spacing: 16) {
                            Button(action: startAR) {
                                HStack {
                                    if arLoading {
                                        ProgressView().tint(.white).padding(.trailing, 8)
                                        if let f = arFraction {
                                            Text(String(format: L("Syncing assets %d%%..."), Int(f * 100)))
                                        } else {
                                            Text("Syncing assets...")
                                        }
                                    } else {
                                        Image(systemName: "arkit").font(.title3.bold())
                                        Text("View in AR").font(.headline)
                                    }
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 60)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .shadow(color: Color.accentColor.opacity(0.3), radius: 12, y: 6)
                            }
                            .disabled(arLoading)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
                .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity)          // and centre that column in the page
            }
            // Content here only just exceeds the screen, so the rubber-band made the page feel like
            // it was sliding at the slightest touch. `.basedOnSize` bounces only when there is
            // genuinely something to scroll to. The 60pt of trailing padding was itself part of the
            // problem - it pushed a page that fits into being scrollable.
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            // Counted here rather than on the list cell: appearing in a scrolling grid is not the
            // same as looking at something, and the profile stat is meant to mean "models I looked at".
            UsageStats.recordCommunityView()
        }
        .fullScreenCover(item: $arReady) { ready in
            StaticARScreen(url: ready.url, title: model.name)
        }
        .fullScreenCover(isPresented: $fullscreenPreview) {
            if let url = embedURL {
                FullscreenPreviewScreen(url: url, title: model.name)
            }
        }
        .alert("Load Failed", isPresented: .constant(arError != nil)) {
            Button("Dismiss") { arError = nil }
        } message: {
            Text(arError ?? "")
        }
    }


    private func statLabel(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded))
        }
    }

    private func startAR() {
        guard !arLoading else { return }
        arReceived = 0
        arTotal = nil
        arLoading = true
        let started = CFAbsoluteTimeGetCurrent()
        Task {
            do {
                let local = try await SketchfabClient.shared.downloadUSDZ(uid: model.uid) { received, total in
                    withAnimation(.easeOut(duration: 0.2)) {
                        arReceived = received
                        arTotal = total
                    }
                }
                await MainActor.run {
                    arLoading = false
                    // Always the app's own AR screen: it is the only one that can be recorded, and
                    // a clip is the point of finding a model in the first place. Models SceneKit
                    // genuinely cannot draw hand themselves off to AR Quick Look from there, once
                    // the loader has reported what the model costs after pruning.
                    Track.log(.communityModelAR, ["model": model.name, "ok": "yes",
                                                  "ms": Track.ms(since: started),
                                                  "mb": (Double(arReceived) / 1e6 * 10).rounded() / 10])
                    arReady = ARModel(url: local)
                }
            } catch {
                await MainActor.run {
                    arLoading = false
                    arError = error.localizedDescription
                    Track.log(.communityModelAR, ["model": model.name, "ok": "no",
                                                  "ms": Track.ms(since: started)])
                }
            }
        }
    }
}


/// The download mask over the model's hero image.
///
/// Takes bytes rather than a fraction, because a fraction is not always knowable: Sketchfab hands
/// out an S3 redirect that frequently carries no Content-Length, and the previous version showed a
/// ring stuck at its 1% minimum and "0%" for the entire download before snapping to 100. A spinning
/// ring with the megabytes received is less precise and far more truthful.
struct DownloadOverlay: View {
    /// 0...1 when the server declared a total, nil when it did not.
    let fraction: Double?
    let received: Int64

    @State private var spin = false

    private var receivedText: String {
        ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 10)

                    if let fraction {
                        Circle()
                            .trim(from: 0, to: max(0.01, fraction))
                            .stroke(
                                LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.25), value: fraction)

                        Text(String(format: L("%d%%"), Int(fraction * 100)))
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    } else {
                        // Total unknown: an arc that keeps turning, so it reads as working rather
                        // than as stalled at zero.
                        Circle()
                            .trim(from: 0, to: 0.22)
                            .stroke(
                                LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(spin ? 360 : 0))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)

                        Text(receivedText)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                }
                .frame(width: 120, height: 120)

                VStack(spacing: 6) {
                    Text("Syncing Assets").font(.headline).foregroundStyle(.white)
                    Text(fraction == nil ? "Preparing high-quality 3D resources"
                                         : LocalizedStringKey(receivedText))
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
        .onAppear { spin = true }
    }
}
