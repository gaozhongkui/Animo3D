//
//  HomeView.swift
//  Animo3D
//
//  首页：主推「舞蹈工作室」+ 更多玩法 + 我的作品。
//  功能入口以全屏(fullScreenCover)方式跳转。
//

import SwiftUI

enum HomeDest: Int, Identifiable {
    case studio, video, tripo
    var id: Int { rawValue }
}

struct HomeView: View {
    @StateObject private var works = WorksStore.shared
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var dest: HomeDest?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("让你的角色在现实里跳舞")
                        .font(.subheadline).foregroundStyle(.secondary)

                    Button { dest = .studio } label: { heroCard }.buttonStyle(.plain)

                    sectionHeader("更多玩法")
                    HStack(spacing: 12) {
                        Button { dest = .video } label: {
                            smallCard(icon: "video", title: "视频驱动", subtitle: "模仿视频动作 · Beta")
                        }.buttonStyle(.plain)
                        Button { dest = .tripo } label: {
                            smallCard(icon: "wand.and.stars", title: "我的角色", subtitle: "个性化 · 照片生成 Beta")
                        }.buttonStyle(.plain)
                    }

                    sectionHeader("我的作品")
                    worksRow
                }
                .padding()
            }
            .navigationTitle("Animo3D")
            .sheet(isPresented: $showShare) {
                if let url = shareURL { ShareSheet(items: [url]) }
            }
            .fullScreenCover(item: $dest) { d in FeatureContainer(dest: d) }
            .onAppear { works.reload() }
        }
    }

    private var heroCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 54, height: 54)
                .overlay(Image(systemName: "figure.dance").font(.title2).foregroundStyle(.tint))
            VStack(alignment: .leading, spacing: 4) {
                Text("舞蹈工作室").font(.headline).foregroundStyle(.tint)
                Text("选角色 · 选舞蹈 · AR 投射到房间")
                    .font(.caption).foregroundStyle(.tint.opacity(0.8))
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
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func smallCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title3).foregroundStyle(.primary)
            Text(title).font(.subheadline.weight(.medium))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var worksRow: some View {
        HStack(spacing: 10) {
            Button { dest = .studio } label: {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(9.0/12.0, contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.secondary))
            }.buttonStyle(.plain)

            ForEach(works.works.prefix(2), id: \.self) { url in
                Button { shareURL = url; showShare = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                        if let img = works.thumbnail(for: url) {
                            Image(uiImage: img).resizable().scaledToFill()
                        }
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote).foregroundStyle(.white)
                            .padding(6).background(.black.opacity(0.4), in: Circle())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(6)
                    }
                    .aspectRatio(9.0/12.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
            }

            ForEach(0..<max(0, 2 - works.works.count), id: \.self) { _ in
                RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground))
                    .aspectRatio(9.0/12.0, contentMode: .fit)
            }
        }
    }

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
    }
}

/// 全屏功能容器：自带 NavigationStack + 可靠的关闭按钮（用 dismiss）。
struct FeatureContainer: View {
    let dest: HomeDest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch dest {
                case .studio: DanceStudioView()
                case .video:  VideoDriveView()
                case .tripo:  TripoGenerateView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
}
