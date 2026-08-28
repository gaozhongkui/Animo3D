//
//  HomeView.swift
//  Animo3D
//
//  「创作」Tab：内容启动台。
//  主推舞蹈工作室 + 推荐角色 / 热门舞蹈（横滑，一键带入工作室）+ 更多玩法。
//

import SwiftUI

enum HomeDest: Int, Identifiable {
    case studio, video, tripo
    var id: Int { rawValue }
}

/// 一次工作室启动配置（可预设角色/舞蹈）。
struct StudioLaunch: Identifiable {
    let id = UUID()
    var character: String? = nil
    var dance: String? = nil
}

struct HomeView: View {
    private let catalog = Catalog.shared
    @State private var launch: StudioLaunch?
    @State private var showVideo = false

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

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

                    // 主推：大横幅
                    Button { launch = StudioLaunch() } label: { heroCard }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal)
                        .shadow(color: Color.accentColor.opacity(0.3), radius: 12, x: 0, y: 8)

                    // 推荐角色
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Recommended Characters") {
                            // 发送通知切换到角色 Tab
                            NotificationCenter.default.post(name: NSNotification.Name("SwitchToCharactersTab"), object: nil)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                                    Button { launch = StudioLaunch(character: c.key) } label: {
                                        posterCard(title: c.name, subtitle: "Ready to Dance") {
                                            CharacterThumbView(characterKey: c.key, tint: tints[i % tints.count])
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // 热门舞蹈
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Trending Dances") {
                            launch = StudioLaunch()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(Array(catalog.dances.prefix(12).enumerated()), id: \.element.id) { i, d in
                                    Button { launch = StudioLaunch(dance: d.key) } label: {
                                        posterCard(title: d.name, subtitle: "Hot Trend") {
                                            if i == 0 {
                                                CardBackdrop(style: 0)
                                                    .overlay(LiveDanceView(model: "vroid_preview.usdz", dance: d.key))
                                            } else {
                                                DanceThumbView(model: "vroid_preview.usdz", dance: d.key, style: i)
                                            }
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // 更多玩法
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("Discover More")
                        VStack(spacing: 12) {
                            Button { showVideo = true } label: {
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
            .fullScreenCover(item: $launch) { l in
                studioCover(DanceStudioView(initialCharacter: l.character, initialDance: l.dance))
            }
            .fullScreenCover(isPresented: $showVideo) {
                studioCover(VideoDriveView())
            }
        }
    }

    // MARK: - 精致组件

    private var heroCard: some View {
        ZStack(alignment: .leading) {
            // 背景装饰
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))

            // 玻璃感图形
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 150, height: 150)
                .offset(x: 200, y: -40)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter Dance Studio")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("Start your immersive AR journey")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    HStack(spacing: 8) {
                        Text("Start Now")
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.white)
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                }

                Spacer()

                Image(systemName: "arkit")
                    .font(.system(size: 60))
                    .foregroundStyle(.white.opacity(0.2))
                    .padding(.trailing, 10)
            }
            .padding(24)
        }
        .frame(height: 160)
    }

    private func posterCard<Thumb: View>(title: String, subtitle: String, @ViewBuilder thumb: () -> Thumb) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                thumb()
                    .frame(width: 140, height: 180)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                // 装饰小标
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

    private func actionCard(icon: String, title: String, subtitle: String, color: Color) -> some View {
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

    private func sectionHeader(_ t: String, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(t)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            if let action = action {
                Button(action: action) {
                    Text("全部")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.horizontal)
    }


    /// 全屏工作室容器（自带关闭按钮）
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
