//
//  RootTabView.swift
//  Animo3D
//
//  产品主结构：首页 / 发现 / 我的 三个底部标签。
//

import SwiftUI

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

/// 发现（社区/热门作品流）—— 占位。
struct DiscoverView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Image(systemName: "safari").font(.largeTitle).foregroundStyle(.secondary)
                Text("发现").font(.headline)
                Text("热门作品与社区，敬请期待")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("发现")
        }
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
