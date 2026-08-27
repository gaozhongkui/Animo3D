//
//  RootTabView.swift
//  Animo3D
//
//  产品主结构：首页 / 发现 / 我的 三个底部标签。
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
                .tabItem { Label("角色", systemImage: "person.3") }
                .tag(1)
            ProfileView()
                .tabItem { Label("我的", systemImage: "person") }
                .tag(2)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SwitchToCharactersTab"))) { _ in
            selection = 1
        }
    }
}

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var selectedModel: SketchfabModel?

    var body: some View {
        VStack(spacing: 0) {
            // 自带搜索框（不再用 NavigationStack，避免顶部空出一条导航栏）
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 3D 模型", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .padding(.horizontal).padding(.bottom, 8)

            DiscoverViewControllerRepresentable(searchText: $searchText) { model in
                self.selectedModel = model
            }
        }
        .fullScreenCover(item: $selectedModel) { model in
            ModelDetailView(model: model)
                .overlay(alignment: .topLeading) {
                    CircleButton(system: "xmark") { selectedModel = nil }
                        .padding(.leading, 12).padding(.top, 6)
                }
        }
    }
}

struct ModelCard: View {
    let model: SketchfabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color(.secondarySystemBackground))
                        .overlay(Image(systemName: "cube").foregroundStyle(.tertiary))
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Text("\(model.likeCount) ❤️")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(6)
            }

            Text(model.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
    }
}

struct ModelDetailView: View {
    let model: SketchfabModel
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false

    // 查看：下载真实模型 → App 内 3D/AR 一体查看器
    @State private var arLoading = false
    @State private var arProgress: Double = 0
    @State private var arError: String?

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 顶部大图 = 主查看入口：点它就进 3D/AR 一体查看器
                    Button(action: startAR) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                            .frame(maxWidth: .infinity)
                            .frame(height: 380)
                            .overlay {
                                AsyncImage(url: URL(string: model.bestThumbnail ?? "")) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "cube").font(.largeTitle).foregroundStyle(.tertiary)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if !arLoading {
                                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                   startPoint: .center, endPoint: .bottom)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if !arLoading {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arkit").font(.title3.weight(.semibold))
                                        Text("在 3D / AR 中查看").font(.subheadline.weight(.semibold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 18).padding(.vertical, 12)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .padding(.bottom, 18)
                                }
                            }
                            .overlay {
                                if arLoading { DownloadOverlay(progress: arProgress) }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
                    }
                    .buttonStyle(.plain)
                    .disabled(arLoading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // 名称 + 数据
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill").foregroundStyle(.red)
                                Text("\(model.likeCount.formattedAbbreviated)")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "eye.fill").foregroundStyle(.secondary)
                                Text("\(model.viewCount.formattedAbbreviated)")
                            }
                            Spacer()
                            Text("精选资源")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)

                    // 次要操作
                    VStack(spacing: 12) {
                        ActionRow(icon: "square.and.arrow.up.fill", title: "分享模型", subtitle: "将这个精美角色分享给你的好友", color: .green) {
                            showShare = true
                        }
                        ActionRow(icon: "safari.fill", title: "详情与下载", subtitle: "在浏览器中查看更多细节并获取源文件", color: .purple) {
                            if let url = URL(string: model.viewerUrl) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["发现一个非常棒的 3D 角色模型：\(model.name)", URL(string: model.viewerUrl)!])
        }
        .alert("无法在 AR 中打开", isPresented: .constant(arError != nil)) {
            Button("知道了", role: .cancel) { arError = nil }
        } message: {
            Text(arError ?? "")
        }
    }

    /// 下载该社区模型的 USDZ，然后用系统 AR Quick Look 打开。
    private func startAR() {
        guard !arLoading else { return }
        arProgress = 0
        arLoading = true
        Task {
            do {
                let local = try await SketchfabClient.shared.downloadUSDZ(uid: model.uid) { p in
                    withAnimation(.easeOut(duration: 0.25)) { arProgress = p }
                }
                await MainActor.run {
                    arLoading = false
                    // App 内轻量 3D 预览（运行时不透明、低内存）；高内存设备预览内可再进 AR
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

/// 友好的下载中覆盖层：磨砂遮罩 + 圆环进度 + 百分比 + 文案。
struct DownloadOverlay: View {
    let progress: Double   // 0…1

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.25)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: max(0.001, progress))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arkit")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 84, height: 84)

                VStack(spacing: 4) {
                    Text("正在准备 3D 模型").font(.subheadline.weight(.semibold))
                    Text("\(Int(progress * 100))%").font(.title3.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
            }
        }
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
            HStack(spacing: 15) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(color, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

