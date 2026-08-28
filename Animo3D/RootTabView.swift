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
    @State private var selectedCategory = "热门"

    private let categories = ["热门", "人物", "动物", "建筑", "车辆", "幻想"]

    var body: some View {
        VStack(spacing: 0) {
            // 精致搜索框
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            .font(.system(size: 14, weight: .bold))
                        TextField("搜索 3D 灵感", text: $searchText)
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

                // 分类标签
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(categories, id: \.self) { cat in
                            Text(cat)
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
                AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Color(.secondarySystemBackground)
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 30))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                // 精致角标
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
                Text("精品模型")
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
    @State private var arProgress: Double = 0
    @State private var arError: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 顶部主展示区：默认静态图，点击开启交互 3D
                    ZStack(alignment: .bottom) {
                        if show3DPreview, let url = URL(string: model.embedUrl) {
                            WebView(url: url)
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
                            AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color(.secondarySystemBackground)
                                    .overlay(Image(systemName: "cube.fill").font(.largeTitle).foregroundStyle(.tertiary))
                            }
                            .frame(height: 400)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { show3DPreview = true }

                            LinearGradient(colors: [.clear, .black.opacity(0.4)],
                                           startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .allowsHitTesting(false)

                            HStack(spacing: 8) {
                                Image(systemName: "move.3d").font(.title3.bold())
                                Text("点击开启 3D 互动").font(.subheadline.bold())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                        }

                        if arLoading { DownloadOverlay(progress: arProgress) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .shadow(color: .black.opacity(0.1), radius: 20, y: 10)

                    // 内容详情
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

                        // 核心操作区
                        VStack(spacing: 16) {
                            Button(action: startAR) {
                                HStack {
                                    if arLoading {
                                        ProgressView().tint(.white).padding(.trailing, 8)
                                        Text("正在同步空间资产 \(Int(arProgress * 100))%...")
                                    } else {
                                        Image(systemName: "arkit").font(.title3.bold())
                                        Text("在现实空间中查看 (AR)").font(.headline)
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
                                ActionRowSmall(icon: "paperplane.fill", title: "分享模型", color: .blue) {
                                    showShare = true
                                }
                                ActionRowSmall(icon: "safari.fill", title: "源地址", color: .indigo) {
                                    if let url = URL(string: model.viewerUrl) { UIApplication.shared.open(url) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 60)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["发现一个超赞的 3D 模型：\(model.name)", URL(string: model.viewerUrl)!])
        }
        .alert("加载失败", isPresented: .constant(arError != nil)) {
            Button("知道了") { arError = nil }
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

struct ActionRowSmall: View {
    let icon: String
    let title: String
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

struct DownloadOverlay: View {
    let progress: Double

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: max(0.01, progress))
                        .stroke(
                            LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 120, height: 120)

                VStack(spacing: 6) {
                    Text("空间资产同步中").font(.headline).foregroundStyle(.white)
                    Text("正在准备高清 3D 模型资源").font(.caption).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 36))
    }
}
