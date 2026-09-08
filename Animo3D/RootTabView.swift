//
//  RootTabView.swift
//  Animo3D
//
//  Main product structure: Home / Characters / Me three bottom tabs.
//

import SwiftUI
import Foundation

struct RootTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Create", systemImage: "sparkles") }
                .tag(0)
            CharactersView()
                .tabItem { Label("Characters", systemImage: "person.2.fill") }
                .tag(1)
            ProfileView()
                .tabItem { Label("Me", systemImage: "person.fill") }
                .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToCharactersTab"))) { _ in
            selection = 1
        }
        .onChange(of: selection) { _ in
            HapticManager.selection()
        }
        .accentColor(.accentColor)
    }
}

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var selectedModel: SketchfabModel?
    @State private var selectedCategory = "Trending"

    private let categories = ["Trending", "Characters", "Animals", "Buildings", "Vehicles", "Fantasy"]

    var body: some View {
        VStack(spacing: 0) {
            // Elegant search box
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            .font(.system(size: 14, weight: .bold))
                        TextField("Search 3D Inspiration", text: $searchText)
                            .font(.system(size: 15))
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 20)

                // Category tags
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories, id: \.self) { cat in
                            Text(LocalizedStringKey(cat))
                                .font(.system(size: 13, weight: selectedCategory == cat ? .bold : .medium))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(selectedCategory == cat ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(selectedCategory == cat ? .white : .primary.opacity(0.7))
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3)) { selectedCategory = cat }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 16)

            DiscoverViewControllerRepresentable(searchText: $searchText, selectedCategory: $selectedCategory) { model in
                self.selectedModel = model
            }
        }
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

struct ModelCard: View {
    let model: SketchfabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Color(.secondarySystemBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .overlay {
                        AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "cube.transparent")
                                .font(.system(size: 30))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                // Elegant badge
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 8))
                    Text(model.likeCount.formattedAbbreviated)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
                .padding(10)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("Featured")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(6)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
    }
}

struct ModelDetailView: View {
    let model: SketchfabModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var show3DPreview = false

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
                        if show3DPreview, let url = URL(string: model.embedUrl) {
                            ZStack {
                                // The web view is transparent, so this placeholder covers the few
                                // seconds the embed needs to load instead of flashing a blank box.
                                Color(.secondarySystemBackground)
                                ProgressView()
                                WebView(url: url)
                            }
                                .frame(maxWidth: .infinity)
                                .frame(height: 400)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { show3DPreview = false } label: {
                                        Image(systemName: "photo.fill")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(10)
                                            .background(.black.opacity(0.6), in: Circle())
                                            .padding(16)
                                    }
                                }
                        } else {
                            // A scaled-to-fill image reports its own oversized width, which used to
                            // stretch the whole page far wider than the screen. Kept as an overlay on a
                            // fixed-size container, it can no longer influence layout.
                            Color(.secondarySystemBackground)
                                .frame(maxWidth: .infinity)
                                .frame(height: 400)
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

                            HStack(spacing: 12) {
                                ActionRowSmall(icon: "paperplane.fill", title: "Share Model", color: .blue) {
                                    showShare = true
                                }
                                ActionRowSmall(icon: "safari.fill", title: "Source Page", color: .indigo) {
                                    if let url = URL(string: model.viewerUrl) { UIApplication.shared.open(url) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 24)
            }
            // Content here only just exceeds the screen, so the rubber-band made the page feel like
            // it was sliding at the slightest touch. `.basedOnSize` bounces only when there is
            // genuinely something to scroll to. The 60pt of trailing padding was itself part of the
            // problem - it pushed a page that fits into being scrollable.
            .scrollBounceBehavior(.basedOnSize)
        }
        .fullScreenCover(item: $arReady) { ready in
            StaticARScreen(url: ready.url, title: model.name)
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["Check out this 3D model: \(model.name)", URL(string: model.viewerUrl)!])
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
                    // The app's own AR screen rather than AR Quick Look: Quick Look places a model
                    // well but is closed, so nothing there could be recorded - and a clip is the
                    // point of finding a model in the first place.
                    arReady = ARModel(url: local)
                }
            } catch {
                await MainActor.run {
                    arLoading = false
                    arError = error.localizedDescription
                }
            }
        }
    }
}

struct ActionRowSmall: View {
    let icon: String
    let title: LocalizedStringKey
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
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
