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

/// 发现（社区/热门作品流）
struct DiscoverView: View {
    @State private var searchText = ""
    @State private var selectedModel: SketchfabModel?
    @State private var isShowingDetail = false

    var body: some View {
        NavigationStack {
            DiscoverViewControllerRepresentable(searchText: $searchText) { model in
                self.selectedModel = model
                self.isShowingDetail = true
            }
            .navigationTitle("社区发现")
            .searchable(text: $searchText, prompt: "搜索 3D 模型")
            .fullScreenCover(isPresented: $isShowingDetail) {
                if let model = selectedModel {
                    NavigationStack {
                        ModelDetailView(model: model)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button {
                                        isShowingDetail = false
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
    @State private var showingStudio = false
    @State private var showShare = false
    @State private var showToast = false
    @State private var toastMsg = ""
    @State private var arMode = false

    // 用于 AR 预览的控制器
    @StateObject private var arController = CharacterSceneController()
    @StateObject private var holder = SceneHolder()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部预览/AR 切换区
            ZStack(alignment: .top) {
                if arMode {
                    ARCharacterView(controller: arController, onAttach: {
                        if !arController.isLoaded {
                            arController.loadModel(named: "tripo_sample.usdz")
                        }
                    }, holder: holder)
                    .background(Color.black)
                    .frame(height: 420)
                } else {
                    if let url = URL(string: model.embedUrl) {
                        WebView(url: url)
                            .frame(height: 420)
                    } else {
                        Rectangle().fill(Color(.secondarySystemBackground))
                            .frame(height: 420)
                            .overlay(Text("无法加载预览"))
                    }
                }

                // 模式切换器
                Picker("", selection: $arMode) {
                    Text("3D 视角").tag(false)
                    Text("AR 模式").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .padding(.top, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: arMode ? 0 : 24, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .padding(.horizontal, arMode ? 0 : 16)
            .padding(.top, arMode ? 0 : 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if arMode {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                            Text("移动手机寻找平面，点击即可放置模型")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.orange)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                        .padding(.top, 16)
                    }

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
                            Text("社区精选资源")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, arMode ? 0 : 16)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("功能操作").font(.system(size: 18, weight: .bold)).padding(.horizontal, 20)

                        VStack(spacing: 12) {
                            ActionRow(icon: "figure.dance", title: "以此角色跳舞", subtitle: "将模型导入舞蹈工作室进行动作同步", color: .orange) {
                                showingStudio = true
                            }

                            ActionRow(icon: "doc.on.doc.fill", title: "复制模型链接", subtitle: "复制该模型的原始访问地址到剪贴板", color: .blue) {
                                UIPasteboard.general.string = model.viewerUrl
                                toastMsg = "链接已复制到剪贴板"
                                showToast = true
                            }

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
                }
                .padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if showToast {
                Text(toastMsg)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation { showToast = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: ["发现一个非常棒的 3D 角色模型：\(model.name)", URL(string: model.viewerUrl)!])
        }
        .alert("功能开发中", isPresented: $showingStudio) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("我们正在优化社区模型的自动下载与绑定技术。目前 AR 模式下显示的是示例预览模型，敬请期待后续更新！")
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
