//
//  ContentView.swift
//  Animo3D
//
//  视频驱动（两步流程）：
//  第一步 选视频 → 预览可重复播放 → 下一步
//  第二步 角色做出视频里的动作（循环）+ 录屏
//

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Combine
import simd

struct VideoDriveView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var previewPlayer: AVPlayer?
    @State private var isLoading = false
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground))
                if let player = previewPlayer {
                    VideoPlayer(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                        Text("选择一个视频作为动作来源").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if isLoading { ProgressView() }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal)

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                    Label(videoURL == nil ? "选择视频" : "重选", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    if let url = videoURL { CharacterMotionView(videoURL: url) }
                } label: {
                    Label("下一步", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoURL == nil)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationTitle("视频驱动")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("src_\(UUID().uuidString).mov")
        try? data.write(to: tmp)
        videoURL = tmp
        setupPreview(tmp)
    }

    private func setupPreview(_ url: URL) {
        let player = AVPlayer(url: url)
        if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in player.seek(to: .zero); player.play() }
        previewPlayer = player
        player.play()
    }
}

/// 管理视频驱动下的角色（可换角色）。vm 固定把动作转发给 stage，stage 永远驱动当前角色。
final class VideoCharStage: ObservableObject {
    @Published private(set) var controller = CharacterSceneController()
    private var retargeter: PoseRetargeter?

    func load(character: String) {
        let c = CharacterSceneController()
        _ = c.loadModel(named: "\(character).scn")
        retargeter = PoseRetargeter(controller: c)
        controller = c
    }
    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }
    func resetRetarget() { retargeter?.resetCapture() }
}

/// 第二步：角色做出视频里的动作（视频在后台循环驱动）+ 选角色 + 屏幕/AR + 录屏。
struct CharacterMotionView: View {
    let videoURL: URL

    private let catalog = Catalog.load()
    @StateObject private var vm = VideoPoseViewModel()
    @StateObject private var stage = VideoCharStage()
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @State private var character = ""
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                Group {
                    if arMode {
                        ARCharacterView(controller: stage.controller,
                                        onAttach: { stage.resetRetarget() }, holder: holder)
                    } else {
                        CharacterSceneView(controller: stage.controller,
                                           onAttach: { stage.resetRetarget() }, holder: holder)
                    }
                }
                .id("\(character)-\(arMode)")

                Picker("", selection: $arMode) {
                    Text("屏幕").tag(false)
                    Text("AR").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 130).padding(8)
            }
            .overlay(alignment: .bottom) { recordButton.padding(.bottom, 14) }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10)

            picker(title: "角色", items: catalog.characters, selection: $character) { new in
                stage.load(character: new)
            }

            Text("关节点 \(vm.landmarks.count)/33 · 动作循环中")
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.landmarks.isEmpty ? Color.secondary : Color.green)
                .padding(.bottom, 6)
        }
        .navigationTitle("角色动作")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .onAppear(perform: setup)
        .onDisappear { vm.stop() }
    }

    private func setup() {
        guard character.isEmpty else { return }
        character = catalog.characters.first?.key ?? "Y_Bot"
        stage.load(character: character)
        vm.onWorld = { [weak stage] world in stage?.drive(world) }   // 固定转发
        vm.load(url: videoURL)      // 后台循环播放视频 → 驱动当前角色
    }

    private func picker(title: String, items: [CatalogItem],
                        selection: Binding<String>, onSelect: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items) { item in
                        let sel = selection.wrappedValue == item.key
                        Text(item.name)
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(sel ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(sel ? .white : .primary)
                            .onTapGesture { selection.wrappedValue = item.key; onSelect(item.key) }
                    }
                }.padding(.horizontal, 12)
            }
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop { url in
                    if let url, let saved = WorksStore.shared.add(from: url) {
                        shareURL = saved; showShare = true
                    }
                }
            } else if let v = holder.scnView {
                recorder.start(view: v)
            }
        } label: {
            Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                .font(.title)
                .foregroundStyle(recorder.isRecording ? .red : .white)
                .padding(12)
                .background(.black.opacity(0.35), in: Circle())
        }
    }
}

#Preview {
    VideoDriveView()
}
