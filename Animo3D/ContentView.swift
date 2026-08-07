//
//  ContentView.swift
//  Animo3D
//

import SwiftUI
import PhotosUI
import AVFoundation

struct ContentView: View {
    @StateObject private var vm = VideoPoseViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoRect: CGRect = .zero
    @State private var isLoadingVideo = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                PlayerView(player: vm.player, videoRect: $videoRect)
                PoseOverlayView(landmarks: vm.landmarks, videoRect: videoRect)
                if isLoadingVideo {
                    ProgressView().tint(.white)
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Text(vm.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("检测到关节点: \(vm.landmarks.count) / 33")
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.landmarks.isEmpty ? Color.secondary : Color.green)

            PhotosPicker(selection: $pickerItem,
                         matching: .videos,
                         photoLibrary: .shared()) {
                Label("选择视频", systemImage: "video.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.bottom)
        }
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task { await loadPickedVideo(newItem) }
        }
    }

    /// PhotosPicker 给的是数据，需要先落地成临时文件再交给 AVPlayer。
    private func loadPickedVideo(_ item: PhotosPickerItem) async {
        isLoadingVideo = true
        defer { isLoadingVideo = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                vm.status = "无法读取视频数据"
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked_\(UUID().uuidString).mov")
            try data.write(to: tmp)
            vm.load(url: tmp)
        } catch {
            vm.status = "加载失败: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView()
}
