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
    private let catalog = Catalog.shared          // Shared: re-parsing the JSON per view rebuild is wasted work

    enum Step: Int, CaseIterable { case video, character, perform }
    @State private var step: Step = .video

    // Step 1 - source clip
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var previewPlayer: AVPlayer?
    @State private var isImporting = false
    @State private var loopObserver: NSObjectProtocol?
    @State private var previewRect: CGRect = .zero

    // Step 2 - performer
    @State private var character = ""
    @State private var zoomChar: CatalogItem?

    // Step 3 - result
    @StateObject private var vm = VideoPoseViewModel()
    @StateObject private var stage = VideoCharStage()
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var processing = false        // Exporting the recording
    @State private var videoRect: CGRect = .zero

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            if step == .perform {
                performStep
            } else {
                VStack(spacing: 0) {
                    stepHeader.padding(.top, 10)

                    ZStack {
                        if step == .video { videoStep } else { characterStep }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().padding(.horizontal)
                    bottomBar.padding(.top, 12)
                }
            }
        }
        .animation(.default, value: step)
        .overlay { if stage.isLoading { loadingHUD } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // The wizard ships its own header and back button
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        .fullScreenCover(item: $zoomChar) { c in
            let idx = catalog.characters.firstIndex { $0.key == c.key } ?? 0
            CharacterPreviewPage(key: c.key, name: c.name, style: idx)
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
        .onDisappear {
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
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                    let isSelected = character == c.key
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            CharacterThumbView(characterKey: c.key, tint: tints[i % tints.count])
                                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                                .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
                                        radius: isSelected ? 10 : 5, x: 0, y: 5)

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
                        character = c.key
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
                                    onAttach: { stage.resetRetarget() }, holder: holder)
                } else {
                    CharacterSceneView(controller: stage.controller,
                                       onAttach: { stage.resetRetarget() }, holder: holder)
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

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                HapticManager.medium()
                recorder.stop { url in
                    guard let url else { return }
                    // Same deal as the dance stage: free exports carry the watermark. Without this
                    // the video-drive path was a way to get clean exports for free.
                    if !ProStore.shared.isPro {
                        processing = true
                        Task {
                            let final = await VideoAudioMixer.export(video: url, audio: nil, watermark: true) ?? url
                            await MainActor.run {
                                HapticManager.success()
                                processing = false
                                if let saved = WorksStore.shared.add(from: final) { shareURL = saved; showShare = true }
                            }
                        }
                    } else if let saved = WorksStore.shared.add(from: url) {
                        HapticManager.success()
                        shareURL = saved; showShare = true
                    }
                }
            } else if let v = holder.scnView {
                HapticManager.medium()
                recorder.start(view: v)
            }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                if processing {
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
        .disabled(processing)
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

    /// Mask while the model is parsed. The character files run to tens of megabytes, so without
    /// feedback the jump into the result page looks like the app has hung.
    private var loadingHUD: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text("Preparing character…").font(.footnote).foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: Logic

    private func next() {
        HapticManager.medium()
        switch step {
        case .video:
            previewPlayer?.pause()
            if character.isEmpty { character = catalog.characters.first?.key ?? "Y_Bot" }
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
            if recorder.isRecording { recorder.stop { _ in } }
            vm.stop()
            dismiss()
        }
    }

    private func startPerform() {
        guard let url = videoURL, !stage.isLoading else { return }
        previewPlayer?.pause()
        vm.onWorld = { [weak stage] world in stage?.drive(world) }
        Task {
            await stage.load(character: character)
            vm.load(url: url)     // Detection only starts once there is something to drive
            step = .perform
        }
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

/// Manages the character under video drive (the character can be swapped). vm always forwards motion to stage, and stage always drives the current character.
final class VideoCharStage: ObservableObject {
    let controller = CharacterSceneController()   // A single instance, models are swapped in place
    private var retargeter: PoseRetargeter?
    @Published var isLoading = false

    init() {
        // Same stage as the dance studio - LED wall, beams, floor and crowd. This screen used to
        // enable nothing at all, so the performer stood in an empty black void while the dance
        // flow got the full venue. Two stages that look nothing alike is just an inconsistency.
        controller.groundEnabled = true
    }

    /// Two-phase load, matching the dance stage: parse off the main thread, mount on it.
    /// This used to call loadModel directly, which parses tens of megabytes synchronously and
    /// froze the screen on entry and on every character switch.
    @MainActor
    func load(character: String) async {
        isLoading = true
        defer { isLoading = false }
        // Characters ship as .scn or .usdz. The old code assumed .scn, so every VRoid character -
        // including the first one in the catalog - silently failed to load and left a black screen.
        let file = characterModelFile(character)
        let loaded = await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(named: file, warmUp: true)
        }.value
        guard let loaded else { NSLog("[VideoDrive] failed to load model %@", file); return }
        _ = controller.install(loaded)
        retargeter = PoseRetargeter(controller: controller)
    }

    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }
    func resetRetarget() { retargeter?.resetCapture() }
}

#Preview {
    VideoDriveView()
}
