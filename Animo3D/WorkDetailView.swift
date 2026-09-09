//
//  WorkDetailView.swift
//  Animo3D
//
//  Creation detail page: plays the recorded video full screen, with share and delete.
//
//  Also serves as the "finished" screen straight after a recording. Stopping the recorder used to
//  throw up the raw share sheet with no confirmation, so it was never clear the clip had been kept -
//  arriving here plays it back and says where it went.
//

import SwiftUI
import AVKit
import StoreKit

struct WorkDetailView: View {
    let url: URL
    /// Set when opened right after recording, to confirm the clip was kept.
    var justSaved = false
    var onClose: () -> Void

    @State private var player = AVPlayer()
    @State private var showShare = false
    /// The item to share, built off the main thread. Nil while it is being built, which is what the
    /// spinner on the Share button is reporting.
    @State private var shareItem: VideoShareItem?
    @State private var preparingShare = false
    @State private var showDeleteConfirm = false
    @State private var showSavedBanner = false

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
                .task {
                    guard justSaved else { return }
                    withAnimation(.spring(response: 0.4)) { showSavedBanner = true }

                    // Review prompt, one second after a successful save - while the user is
                    // looking at something they just made and are pleased with.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                            SKStoreReviewController.requestReview(in: scene)
                        }
                    }

                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { showSavedBanner = false }
                }

            // Top: close
            HStack {
                CircleButton(system: "xmark") { player.pause(); onClose() }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8)

            if showSavedBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Saved to My Creations")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 72)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Bottom: share / delete
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    shareButton
                    actionButton("trash", "Delete", tint: .red) { showDeleteConfirm = true }
                }
                .padding(.bottom, 36)
            }
        }
        .sheet(isPresented: $showShare) {
            // The prepared item when it is ready, the bare URL if the thumbnail could not be made -
            // a missing preview is not a reason to refuse to share.
            ShareSheet(items: [shareItem ?? url])
        }
        .confirmationDialog("Delete this creation?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.pause()
                WorksStore.shared.delete(url)
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Share, with the wait made visible and made shorter.
    ///
    /// Two separate delays were stacked here. The share sheet decodes a frame out of the movie to
    /// build its header preview, and it does that on the main thread after the tap - so the button
    /// sat there looking broken for a beat. `VideoShareItem` removes that by handing the sheet a
    /// thumbnail; generating *that* thumbnail is itself an `AVAssetImageGenerator` decode, so it
    /// happens off the main thread here, with the button showing a spinner while it runs.
    private var shareButton: some View {
        Button {
            guard !preparingShare else { return }
            HapticManager.light()
            if shareItem != nil { showShare = true; return }   // already prepared
            preparingShare = true
            Task.detached(priority: .userInitiated) {
                let thumb = WorksStore.shared.thumbnail(for: url)
                let item = VideoShareItem(url: url, title: L("My Creation"), thumbnail: thumb)
                await MainActor.run {
                    shareItem = item
                    preparingShare = false
                    showShare = true
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title2)
                        .opacity(preparingShare ? 0 : 1)
                    if preparingShare { ProgressView().tint(.white) }
                }
                .frame(height: 26)
                Text("Share").font(.caption)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(preparingShare)
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
