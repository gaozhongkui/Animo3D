//
//  ContentView.swift
//  Animo3D
//
//  Video drive, as a three-step wizard matching the dance studio:
//  Step 1 pick the source clip -> Step 2 pick who performs it -> Step 3 the finished result
//

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import Combine
import simd

struct VideoDriveView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var remoteAssets = RemoteAssets.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var showPaywall = false
    @State private var pendingProAction: ProAction?

    private enum ProAction {
        case character(String)
        case perform
        case record
    }

    private var contentAccess: ProContentAccess { remoteAssets.proContentAccess }

    enum Step: Int, CaseIterable { case video, character, perform }
    @State private var step: Step = .video
    @State private var loadingStage = false
    @State private var preparationTask: Task<Void, Never>?

    // Step 1 - source clip
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var previewPlayer: AVPlayer?
    @State private var isImporting = false
    @State private var loopObserver: NSObjectProtocol?
    @State private var previewRect: CGRect = .zero

    // Step 2 - performer
    @State private var character = ""
    @State private var zoomChar: CharacterItem?

    // Step 3 - result
    @StateObject private var vm = VideoPoseViewModel()
    @StateObject private var stage = DancePerformer(owner: "VideoDrive", groundEnabled: true)
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @StateObject private var recordingOutput = RecordingOutput()
    @State private var videoRect: CGRect = .zero


    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if step == .perform {
                performStep				
            } else {
                VStack(spacing: 0) {
                    stepHeader.padding(.top, 10)

                    // Content area: Use if/else to ensure stable View identity and prevent layout collapse
                    ZStack {
                        if step == .video { videoStep } else { characterStep }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().padding(.horizontal)
                    bottomBar.padding(.top, 12)
                }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.default, value: step)
        .overlay {
            if let failure = stage.loadFailure {
                AssetLoadingFailureView(
                    failure: failure,
                    onRetry: startPerform,
                    onClose: cancelPreparation
                )
            } else if loadingStage {
                StageLoadingHUD(
                    progress: remoteAssets.activeDownloadProgress,
                    onCancel: cancelPreparation
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // The wizard ships its own header and back button
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        .recordingFeedback(output: recordingOutput)
        .fullScreenCover(isPresented: $showPaywall, onDismiss: resumeProAction) {
            PaywallView(onClose: { showPaywall = false }, source: "video_drive_content")
        }
        .onChange(of: pro.isPro) { isPro in
            if !isPro {
                if recorder.isRecording { stopRecording() }
                if pro.characterLocked(character, in: contentAccess) {
                    vm.stop()
                    stage.pause()
                }
            } else if step == .perform, let videoURL {
                stage.resume()
                vm.load(url: videoURL)
            }
        }
        .fullScreenCover(item: $zoomChar) { c in
            let idx = remoteAssets.characters.firstIndex { $0.id == c.id } ?? 0
            CharacterPreviewPage(key: c.id, name: c.name, style: idx)
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .onDisappear {
            if recorder.isRecording { stopRecording() }
            preparationTask?.cancel()
            preparationTask = nil
            if loadingStage {
                loadingStage = false
                stage.unload()
            }
            // The loop observer and the preview player both used to outlive this screen, so the
            // preview kept playing (and holding the file) after leaving.
            if let obs = loopObserver { NotificationCenter.default.removeObserver(obs) }
            loopObserver = nil
            previewPlayer?.pause()
            vm.stop()
        }
    }

    // MARK: Header

    private var stepHeader: some View {
        let titles: [LocalizedStringKey] = ["Select Video", "Select Character", "Character Motion"]
        return HStack(spacing: 20) {
            CircleButton(system: step == .video ? "xmark" : "chevron.left") { back() }

            VStack(alignment: .leading, spacing: 2) {
                Text(titles[step.rawValue])
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Step \(step.rawValue + 1) of 3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i <= step.rawValue ? Color.accentColor : Color.accentColor.opacity(0.2))
                        .frame(width: i == step.rawValue ? 20 : 8, height: 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: Step 1 - pick the source clip

    private var videoStep: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemBackground))

                if let player = previewPlayer {
                    // Deliberately not AVKit's VideoPlayer. Now that the steps live in one view,
                    // moving on tears its AVPlayerViewController out of an animating container,
                    // and AVKit crashes messaging a released object on the way down. PlayerView is
                    // a plain AVPlayerLayer with no view-controller lifecycle to unwind.
                    PlayerView(player: player, videoRect: $previewRect)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 42))
                            .foregroundStyle(Color.accentColor)
                        Text("Select a video as motion source")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if isImporting { ProgressView() }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 16)

            // Tracking needs a whole body in shot; saying so here saves a pointless round trip
            // through detection with a clip that can never work.
            Label("Full body in frame, one person, steady shot works best", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)

            PhotosPicker(selection: $pickerItem, matching: .videos, photoLibrary: .shared()) {
                Label(videoURL == nil ? "Select Video" : "Reselect", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 4)
        }
    }

    // MARK: Step 2 - pick who performs it

    private var characterStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(Array(remoteAssets.characters.enumerated()), id: \.element.id) { i, c in
                    let isSelected = character == c.id
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            CharacterThumbView(characterKey: c.id, style: i)
                                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(isSelected ? CardBackdrop.accent(for: i).opacity(0.95)
                                                           : .white.opacity(0.12),
                                                lineWidth: isSelected ? 2.5 : 0.5)
                                )
                                .shadow(color: isSelected ? CardBackdrop.accent(for: i).opacity(0.4)
                                                          : .black.opacity(0.25),
                                        radius: isSelected ? 15 : 8, x: 0, y: isSelected ? 8 : 4)

                            if pro.characterLocked(c.id, in: contentAccess) {
                                ProLockBadge()
                                    .padding(12)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            }
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.white, Color.accentColor)
                                    .font(.title2)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            }
                        }

                        Text(c.name)
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 4)
                    }
                    .onTapGesture {
                        HapticManager.light()
                        chooseCharacter(c.id)
                    }
                    .overlay(alignment: .topTrailing) {
                        ZoomButton { zoomChar = c }
                            .padding(12)
                            .opacity(isSelected ? 1 : 0.6)
                    }
                }
            }
            .padding(.horizontal).padding(.bottom, 20)
        }
    }

    // MARK: Step 3 - the result

    private var performStep: some View {
        ZStack {
            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller,
                                    onAttach: { stage.rebaseRetarget() },
                                    onRelocated: { stage.rebaseRetarget() }, holder: holder)
                } else {
                    CharacterSceneView(controller: stage.controller,
                                       onAttach: { stage.rebaseRetarget() }, holder: holder)
                }
            }
            .id(arMode)   // Rebuilt only when switching between screen and AR
            .ignoresSafeArea()

            if arMode { ARCoachView().transition(.opacity) }

            VStack(spacing: 0) {
                HStack {
                    CircleButton(system: "chevron.left") { back() }
                    Spacer()
                    Picker("", selection: $arMode) {
                        Text("Screen").tag(false)
                        Text("AR").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 130)
                }
                .padding(.horizontal, 16).padding(.top, 6)

                HStack {
                    Spacer()
                    sourcePiP
                }
                .padding(.horizontal, 16).padding(.top, 10)

                Spacer()

                VStack(spacing: 12) {
                    // What the user needs to know is simply whether the motion is being picked up.
                    Label(vm.landmarks.isEmpty ? "Looking for a person…" : "Motion locked",
                          systemImage: vm.landmarks.isEmpty ? "person.fill.questionmark" : "figure.walk.motion")
                        .font(.caption)
                        .foregroundStyle(vm.landmarks.isEmpty ? Color.white.opacity(0.7) : Color.green)

                    recordButton
                }
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
    }

    /// The source clip, small, with the tracked skeleton drawn on it. Without this the result page
    /// gives no clue where the motion comes from, or whether tracking actually caught the person.
    private var sourcePiP: some View {
        ZStack {
            PlayerView(player: vm.player, videoRect: $videoRect)
            PoseOverlayView(landmarks: vm.landmarks, videoRect: videoRect)
        }
        .frame(width: 92, height: 122)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.25), lineWidth: 1))
        .overlay(alignment: .bottom) {
            Text("Source")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(4)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private func requestPro(_ action: ProAction, id: String) {
        Track.log(.lockedItemTapped, ["kind": "character", "id": id, "source": "video_drive"])
        pendingProAction = action
        showPaywall = true
    }

    private func chooseCharacter(_ id: String) {
        guard remoteAssets.characters.contains(where: { $0.id == id }) else { return }
        guard !pro.characterLocked(id, in: contentAccess) else {
            requestPro(.character(id), id: id)
            return
        }
        character = id
    }

    private func requireCharacterAccess(for action: ProAction) -> Bool {
        guard !character.isEmpty,
              remoteAssets.characters.contains(where: { $0.id == character }) else { return false }
        guard !pro.characterLocked(character, in: contentAccess) else {
            requestPro(action, id: character)
            return false
        }
        return true
    }

    private func resumeProAction() {
        guard let action = pendingProAction else { return }
        pendingProAction = nil
        guard pro.isPro else { return }
        switch action {
        case .character(let id): chooseCharacter(id)
        case .perform: startPerform()
        case .record:
            stage.resume()
            if let videoURL { vm.load(url: videoURL) }
            startRecording()
        }
    }

    private func startRecording() {
        guard requireCharacterAccess(for: .record) else { return }
        guard let view = holder.scnView else {
            recordingOutput.reportRecordingError(RecordingError.sceneUnavailable)
            return
        }
        do {
            try recorder.start(view: view, watermark: pro.isPro ? nil : "Livo 3D")
        } catch {
            recordingOutput.reportRecordingError(error)
        }
    }

    private func stopRecording() {
        recorder.stop { result in
            Task { await recordingOutput.process(result) }
        }
    }

    private var recordButton: some View {
        Button {
            HapticManager.medium()
            if recorder.isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                if recordingOutput.isProcessing || recorder.isFinishing {
                    ProgressView().tint(.white)
                } else {
                    RoundedRectangle(cornerRadius: recorder.isRecording ? 7 : 30, style: .continuous)
                        .fill(Color.red)
                        .frame(width: recorder.isRecording ? 30 : 60,
                               height: recorder.isRecording ? 30 : 60)
                }
            }
            .frame(width: 80, height: 80)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recorder.isRecording)
        }
        .disabled(recordingOutput.isProcessing || recorder.isFinishing)
    }

    // MARK: Bottom button

    private var bottomBar: some View {
        Button(action: next) {
            HStack(spacing: 8) {
                Text(step == .character ? "Start Performance" : "Next")
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(canAdvance ? Color.accentColor : Color.gray.opacity(0.4),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .disabled(!canAdvance)
    }

    private var canAdvance: Bool {
        switch step {
        case .video:     return videoURL != nil
        case .character: return !character.isEmpty
        case .perform:   return false
        }
    }

    // MARK: Logic

    private func next() {
        HapticManager.medium()
        switch step {
        case .video:
            previewPlayer?.pause()
            if character.isEmpty {
                character = remoteAssets.characters.first {
                    !pro.characterLocked($0.id, in: contentAccess)
                }?.id ?? ""
            }
            step = .character
        case .character:
            startPerform()
        case .perform:
            break
        }
    }

    private func back() {
        switch step {
        case .video:     dismiss()
        case .character:
            step = .video
            previewPlayer?.play()
        case .perform:
            // Back from the result page leaves the studio outright, the same as the dance stage:
            // returning to the picker with a live detector running just burns the CPU.
            if recorder.isRecording { stopRecording() }
            vm.stop()
            dismiss()
        }
    }

    private func startPerform() {
        guard let url = videoURL, !loadingStage, requireCharacterAccess(for: .perform) else { return }
        loadingStage = true
        previewPlayer?.pause()
        vm.onWorld = { [weak stage] world in stage?.drive(world) }
        preparationTask = Task {
            defer { if !Task.isCancelled { loadingStage = false } }
            guard await stage.load(character: character), !Task.isCancelled,
                  requireCharacterAccess(for: .perform) else { return }
            vm.load(url: url)     // Detection only starts once there is something to drive
            step = .perform
        }
    }

    private func cancelPreparation() {
        preparationTask?.cancel()
        preparationTask = nil
        loadingStage = false
        stage.unload()
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        // Each pick used to leave its copy behind in tmp for the rest of the install.
        if let old = videoURL { try? FileManager.default.removeItem(at: old) }
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

#Preview {
    VideoDriveView()
}
