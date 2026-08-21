//
//  RootTabView.swift
//  Animo3D
//
//  产品主结构：首页 / 发现 / 我的 三个底部标签。
//

import SwiftUI
import Foundation

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("首页", systemImage: "house") }
            DiscoverView()
                .tabItem { Label("发现", systemImage: "safari") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person") }
        }
    }
}

struct DiscoverView: View {
    @State private var searchText = ""
    @State private var selectedModel: SketchfabModel?

    var body: some View {
        NavigationStack {
            DiscoverViewControllerRepresentable(searchText: $searchText) { model in
                self.selectedModel = model
            }
            .navigationTitle("社区发现")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索 3D 模型")
            .fullScreenCover(item: $selectedModel) { model in
                NavigationStack {
                    ModelDetailView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    selectedModel = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.title3)
                                }
                            }
                        }
                }
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
                                LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                               startPoint: .center, endPoint: .bottom)
                            }
                            .overlay(alignment: .bottom) {
                                HStack(spacing: 8) {
                                    if arLoading {
                                        ProgressView().tint(.white)
                                        Text("正在下载模型…").font(.subheadline.weight(.semibold))
                                    } else {
                                        Image(systemName: "arkit").font(.title3.weight(.semibold))
                                        Text("在 3D / AR 中查看").font(.subheadline.weight(.semibold))
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(.black.opacity(0.45), in: Capsule())
                                .padding(.bottom, 18)
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
        arLoading = true
        Task {
            do {
                let local = try await SketchfabClient.shared.downloadUSDZ(uid: model.uid)
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

/// 我的（作品、设置、实验功能）—— 占位。
struct ProfileView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("作品") {
                    Text("我录制的跳舞视频").foregroundStyle(.secondary)
                }
                Section("实验功能") {
                    NavigationLink { ARBodyEntryView() } label: {
                        Label("ARKit 实时人体追踪", systemImage: "figure.walk.motion")
                    }
                }
                Section("关于") {
                    Text("Animo3D").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
    }
}
