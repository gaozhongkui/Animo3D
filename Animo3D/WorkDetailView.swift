//
//  WorkDetailView.swift
//  Animo3D
//
//  作品详情页：全屏播放录制的视频,可分享/删除。
//

import SwiftUI
import AVKit

struct WorkDetailView: View {
    let url: URL
    var onClose: () -> Void

    @State private var player = AVPlayer()
    @State private var showShare = false
    @State private var showDeleteConfirm = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()
                .onAppear {
                    player.replaceCurrentItem(with: AVPlayerItem(url: url))
                    player.play()
                    // 循环播放
                    NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                           object: player.currentItem, queue: .main) { _ in
                        player.seek(to: .zero); player.play()
                    }
                }
                .onDisappear { player.pause() }

            // 顶部：关闭
            HStack {
                CircleButton(system: "xmark") { player.pause(); onClose() }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)

            // 底部：分享 / 删除
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    actionButton("square.and.arrow.up", "分享") { showShare = true }
                    actionButton("trash", "删除", tint: .red) { showDeleteConfirm = true }
                }
                .padding(.bottom, 36)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
        .confirmationDialog("删除这个作品?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                player.pause()
                WorksStore.shared.delete(url)
                onClose()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func actionButton(_ icon: String, _ title: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.caption)
            }
            .foregroundStyle(tint)
            .frame(width: 64, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
