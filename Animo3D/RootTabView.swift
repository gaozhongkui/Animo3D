//
//  RootTabView.swift
//  Animo3D
//
//  产品主结构：首页 / 角色 / 我的 三个底部标签。
//

import SwiftUI
import Foundation

struct RootTabView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("创作", systemImage: "sparkles") }
                .tag(0)
            CharactersView()
                .tabItem { Label("角色", systemImage: "person.2.fill") }
                .tag(1)
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.fill") }
                .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToCharactersTab"))) { _ in
            selection = 1
        }
        .accentColor(.accentColor)
    }
}

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var selectedModel: SketchfabModel?

    var body: some View {
        VStack(spacing: 0) {
            // 精致搜索框
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .font(.system(size: 14, weight: .bold))
                    TextField("搜索 3D 模型", text: $searchText)
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
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, 20).padding(.bottom, 12)

            DiscoverViewControllerRepresentable(searchText: $searchText) { model in
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
    }
}

struct ModelCard: View {
    let model: SketchfabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color(.secondarySystemBackground))
                        .overlay(Image(systemName: "cube.fill").foregroundStyle(.tertiary).font(.title))
                }
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("\(model.likeCount.formattedAbbreviated) ❤️")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }

            Text(model.name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .padding(6)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 5)
    }
}

struct ModelDetailView: View {
    let model: SketchfabModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    @State private var arLoading = false
    @State private var arProgress: Double = 0
    @State private var arError: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 顶部大图 = 主查看入口
                    Button(action: startAR) {
                        ZStack(alignment: .bottom) {
                            AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.secondarySystemBackground)
                                    .overlay(Image(systemName: "cube.fill").font(.largeTitle).foregroundStyle(.tertiary))
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

                            if !arLoading {
                                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                               startPoint: .center, endPoint: .bottom)
                                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

                                HStack(spacing: 10) {
                                    Image(systemName: "arkit").font(.title3.bold())
                                    Text("进入 AR / 3D 预览").font(.subheadline.bold())
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24).padding(.vertical, 14)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(.bottom, 30)
                            }

                            if arLoading { DownloadOverlay(progress: arProgress) }
                        }
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(arLoading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.name)
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(.primary)

                        HStack(spacing: 16) {
                            statLabel(icon: "heart.fill", value: model.likeCount.formattedAbbreviated, color: .red)
                            statLabel(icon: "eye.fill", value: model.viewCount.formattedAbbreviated, color: .secondary)
                            Spacer()
                            Text("社区精品")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 14) {
                        ActionRow(icon: "square.and.arrow.up.fill", title: "分享给好友", subtitle: "发现有趣的 3D 灵魂", color: .blue) {
                            showShare = true
                        }
                        ActionRow(icon: "safari.fill", title: "访问源地址", subtitle: "前往 Sketchfab 查看详情", color: .indigo) {
                            if let url = URL(string: model.viewerUrl) { UIApplication.shared.open(url) }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 50)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["看看这个 3D 模型：\(model.name)", URL(string: model.viewerUrl)!])
        }
        .alert("加载失败", isPresented: .constant(arError != nil)) {
            Button("知道了") { arError = nil }
        } message: {
            Text(arError ?? "")
        }
    }

    private func statLabel(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.system(size: 14, weight: .bold).monospacedDigit())
        }
    }

    private func startAR() {
        guard !arLoading else { return }
        arProgress = 0
        arLoading = true
        Task {
            do {
                let local = try await SketchfabClient.shared.downloadUSDZ(uid: model.uid) { p in
                    withAnimation(.easeOut(duration: 0.2)) { arProgress = p }
                }
                await MainActor.run {
                    arLoading = false
                    ARQuickLookPresenter.shared.presentPreview(url: local, title: model.name)
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

struct DownloadOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: max(0.01, progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 100, height: 100)

                Text("正在同步空间资产...").font(.subheadline.bold()).foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

struct ActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
