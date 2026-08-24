//
//  CharactersView.swift
//  Animo3D
//
//  「角色」Tab：主线的"弹药库"。
//  - 我的角色：可跳舞的角色(内置；后续接 Cloudflare manifest 下载缓存)。点角色→用它跳舞。
//  - 社区：Sketchfab 浏览 / AR 查看(仅查看，不参与跳舞)，从原一级 Tab 降级为这里的子分区。
//

import SwiftUI

struct CharactersView: View {
    @State private var seg = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $seg) {
                Text("我的角色").tag(0)
                Text("社区").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)

            if seg == 0 {
                MyCharactersView()
            } else {
                DiscoverView()   // Sketchfab 浏览/AR（仅查看）
            }
        }
    }
}

private struct PickedCharacter: Identifiable { let id: String; let name: String }

/// 我的角色：可跳舞的角色库。点一个 → 进舞蹈工作室并带入该角色。
struct MyCharactersView: View {
    private let catalog = Catalog.load()
    @State private var picked: PickedCharacter?
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 16) {
                ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                    Button { picked = PickedCharacter(id: c.key, name: c.name) } label: {
                        card(c.name, key: c.key, tint: tints[i % tints.count])
                    }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .fullScreenCover(item: $picked) { p in
                NavigationStack {
                    DanceStudioView(initialCharacter: p.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button { picked = nil } label: {
                                    Image(systemName: "xmark").font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                }
            }
        }

    // MARK: 卡片
    private func card(_ name: String, key: String, tint: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            CharacterThumbView(characterKey: key, tint: tint)
                .aspectRatio(3.0/4.0, contentMode: .fill)

            LinearGradient(colors: [.clear, .black.opacity(0.55)],
                           startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "play.circle.fill")
                    Text("用它跳舞")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(10)
        }
        .aspectRatio(3.0/4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 3)
    }
}
