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
    private let catalog = Catalog.load()
    @State private var launch: StudioLaunch?
    @State private var showVideo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("让你的角色在现实里跳舞")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.horizontal)

                    // 主推
                    Button { launch = StudioLaunch() } label: { heroCard }
                        .buttonStyle(.plain).padding(.horizontal)

                    // 推荐角色（横滑，真实角色形象，点→带入工作室）
                    section("推荐角色") {
                        ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                            Button { launch = StudioLaunch(character: c.key) } label: {
                                posterCard(title: c.name) {
                                    CharacterThumbView(characterKey: c.key, tint: tints[i % tints.count])
                                }
                            }.buttonStyle(.plain)
                        }
                    }

                    // 热门舞蹈（横滑，女孩摆出动作，第一张实时跳动，点→带入工作室）
                    section("热门舞蹈") {
                        ForEach(Array(catalog.dances.prefix(12).enumerated()), id: \.element.id) { i, d in
                            Button { launch = StudioLaunch(dance: d.key) } label: {
                                posterCard(title: d.name) {
                                    if i == 0 {
                                        CardBackdrop(style: 0).overlay(LiveDanceView(model: "vroid_preview.usdz", dance: d.key))
                                    } else {
                                        DanceThumbView(model: "vroid_preview.usdz", dance: d.key, style: i)
                                    }
                                }
                            }.buttonStyle(.plain)
                        }
                    }

                    // 更多玩法
                    sectionHeader("更多玩法")
                    Button { showVideo = true } label: {
                        smallCard(icon: "video", title: "视频驱动", subtitle: "模仿视频动作 · Beta")
                    }.buttonStyle(.plain).padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("创作")
            .fullScreenCover(item: $launch) { l in
                studioCover(DanceStudioView(initialCharacter: l.character, initialDance: l.dance))
            }
            .fullScreenCover(isPresented: $showVideo) {
                studioCover(VideoDriveView())
            }
        }
    }

    // MARK: 组件

    private var heroCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground).opacity(0.6))
                .frame(width: 60, height: 60)
                .overlay(Image(systemName: "figure.dance").font(.title).foregroundStyle(.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text("舞蹈工作室").font(.title3.weight(.semibold)).foregroundStyle(.tint)
                Text("选角色 · 选舞蹈 · AR 投射到房间")
                    .font(.caption).foregroundStyle(.tint.opacity(0.85))
                Label("开始跳舞", systemImage: "play.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(.systemBackground), in: Capsule())
                    .foregroundStyle(.tint)
                    .padding(.top, 6)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
    }

    /// 带横滑内容的分区
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { content() }.padding(.horizontal)
            }
        }
    }

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    /// 竖版海报卡：缩略图 + 底部名称。
    private func posterCard<Thumb: View>(title: String, @ViewBuilder thumb: () -> Thumb) -> some View {
        ZStack(alignment: .bottomLeading) {
            thumb()
                .frame(width: 132, height: 168)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .lineLimit(1).padding(8)
        }
        .frame(width: 132, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    private func smallCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.headline).padding(.horizontal)
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
