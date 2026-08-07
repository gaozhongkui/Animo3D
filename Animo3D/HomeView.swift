//
//  HomeView.swift
//  Animo3D
//
//  主页：两个入口，分别测试两条人体动作驱动方案。
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                Text("Animo3D")
                    .font(.largeTitle.bold())
                Text("选择一种动作驱动方式")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                NavigationLink { VideoDriveView() } label: {
                    entryCard(icon: "video.fill",
                              title: "视频驱动",
                              subtitle: "BlazePose · 解析视频动作驱动 3D 角色\n任意机型可用",
                              tint: .blue)
                }

                NavigationLink { ARBodyEntryView() } label: {
                    entryCard(icon: "figure.walk.motion",
                              title: "ARKit 实时人体追踪",
                              subtitle: "苹果原生 · 摄像头实时骨架\n需 A12+ 真机",
                              tint: .purple)
                }

                NavigationLink { TripoGenerateView() } label: {
                    entryCard(icon: "wand.and.stars",
                              title: "Tripo3D 生成角色",
                              subtitle: "相册选图 → 生成 3D 模型 → 下载\n（跳舞驱动为下一步）",
                              tint: .pink)
                }

                Spacer()
                Spacer()
            }
            .padding()
        }
    }

    private func entryCard(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(tint, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    HomeView()
}
