//
//  ContentView.swift
//  Animo3D
//

import SwiftUI
import PhotosUI
import AVFoundation

struct VideoDriveView: View {
    @StateObject private var vm = VideoPoseViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoRect: CGRect = .zero
    @State private var isLoadingVideo = false

    // 调试开关：自动加载包内测试视频（校准完成后置为 false）
    private let debugAutoLoadTestClip = false
    // 调试开关：喂已知合成姿势，确定性校准坐标轴
    private let debugSyntheticPose = false

    // 3D 角色
    private let character = CharacterSceneController()
    @State private var retargeter: PoseRetargeter?
    @State private var boneCount = 0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                // 左：视频 + 2D 骨架叠加
                ZStack {
                    Color.black
                    PlayerView(player: vm.player, videoRect: $videoRect)
                    PoseOverlayView(landmarks: vm.landmarks, videoRect: videoRect)
                    if isLoadingVideo { ProgressView().tint(.white) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // 右：3D 角色（被动作驱动）
                CharacterSceneView(controller: character)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10)

            Text(vm.status)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("关节点 \(vm.landmarks.count)/33 · 骨骼 \(boneCount)")
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
        .navigationTitle("视频驱动 · BlazePose")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: setupCharacter)
        .onChange(of: pickerItem) { newItem in
            guard let newItem else { return }
            Task { await loadPickedVideo(newItem) }
        }
    }

    private func setupCharacter() {
        guard retargeter == nil else { return }
        let bones = character.loadModel(named: "character.scn")
        boneCount = bones.count
        let rt = PoseRetargeter(controller: character)
        retargeter = rt
        vm.onWorld = { world in rt.apply(world: world) }

        // 调试：启动即自动加载包内测试视频，便于快速迭代重定向坐标轴
        if debugAutoLoadTestClip,
           let url = Bundle.main.url(forResource: "testclip", withExtension: "mp4") {
            vm.load(url: url)
        }

        // 调试：喂一个已知姿势（双臂向前），确定性验证坐标轴
        if debugSyntheticPose {
            let pose = PoseRetargeter.debugArmsForwardPose()
            Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                rt.apply(world: pose)
            }
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
    VideoDriveView()
}
