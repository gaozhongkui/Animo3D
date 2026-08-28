//
//  ContentView.swift
//  Animo3D
//
//  Video drive (a two-step flow):
//  Step 1: pick a video -> preview it on repeat -> Next
//  Step 2: the character performs the motion from the video (looping) + screen recording
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
                        Text("Select a video as motion source").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if isLoading { ProgressView() }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal)

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                    Label(videoURL == nil ? "Select Video" : "Reselect", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                NavigationLink {
                    if let url = videoURL { CharacterMotionView(videoURL: url) }
                } label: {
                    Label("Next", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoURL == nil)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationTitle("Video Drive")
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

/// Manages the character under video drive (the character can be swapped). vm always forwards motion to stage, and stage always drives the current character.
final class VideoCharStage: ObservableObject {
    let controller = CharacterSceneController()   // A single instance, models are swapped in place
    private var retargeter: PoseRetargeter?

    func load(character: String) {
        _ = controller.loadModel(named: "\(character).scn")   // Reuse the scene, swap the model
        retargeter = PoseRetargeter(controller: controller)
    }
    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }
    func resetRetarget() { retargeter?.resetCapture() }
}

/// Step 2: the character performs the motion from the video (the video loops in the background) + character picker + screen/AR + recording.
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
                .id(arMode)   // Rebuilt only when switching between screen and AR; swapping characters replaces the model in place without a rebuild

                Picker("", selection: $arMode) {
                    Text("Screen").tag(false)
                    Text("AR").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 130).padding(8)
            }
            .overlay(alignment: .bottom) { recordButton.padding(.bottom, 14) }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10)

            picker(title: "Character", items: catalog.characters, selection: $character) { new in
                stage.load(character: new)
            }

            Text("Joints \(vm.landmarks.count)/33 · Loop Playing")
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.landmarks.isEmpty ? Color.secondary : Color.green)
                .padding(.bottom, 6)
        }
        .navigationTitle("Character Motion")
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
        vm.onWorld = { [weak stage] world in stage?.drive(world) }   // Fixed forwarding
        vm.load(url: videoURL)      // Loops the video in the background -> drives the current character
    }

    private func picker(title: LocalizedStringKey, items: [CatalogItem],
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
