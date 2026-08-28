//
//  WorkDetailView.swift
//  Animo3D
//
//  Creation detail page: plays the recorded video full screen, with share and delete.
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
                    // Loop playback
                    NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                           object: player.currentItem, queue: .main) { _ in
                        player.seek(to: .zero); player.play()
                    }
                }
                .onDisappear { player.pause() }

            // Top: close
            HStack {
                CircleButton(system: "xmark") { player.pause(); onClose() }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)

            // Bottom: share / delete
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    actionButton("square.and.arrow.up", "Share") { showShare = true }
                    actionButton("trash", "Delete", tint: .red) { showDeleteConfirm = true }
                }
                .padding(.bottom, 36)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: [url]) }
        .confirmationDialog("Delete this creation?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.pause()
                WorksStore.shared.delete(url)
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionButton(_ icon: String, _ title: LocalizedStringKey, tint: Color = .white, action: @escaping () -> Void) -> some View {
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
