//
//  DanceStudioView.swift
//  Animo3D
//
//  Dance Studio: Select Character + Select Dance -> Character starts dancing.
//  Character .scn and dance .json are both from the App bundle; the list is described by manifest.json (can be replaced with network downloads later).
//

import SwiftUI
import SceneKit
import Combine

struct CatalogItem: Identifiable, Decodable {
    let key: String
    let name: String
    var id: String { key }
}
struct Catalog: Decodable {
    let characters: [CatalogItem]
    let dances: [CatalogItem]

    /// manifest.json is a read-only static manifest, parsing it once globally is enough.
    /// Previously written as a stored property of the View, SwiftUI would re-read and re-parse it every time the struct was rebuilt.
    static let shared = load()

    static func load() -> Catalog {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(characters: [], dances: [])
        }
        return c
    }
}

/// Manage the current character + the dance being played.
final class DanceStage: ObservableObject {
    let controller: CharacterSceneController = {
        let c = CharacterSceneController()
        c.groundEnabled = true   // Performance page shows ground + shadows
        return c
    }()
    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var vroidPlayer: VRoidClipPlayer?

    /// Load character + dance. **All heavy lifting is on background threads**:
    /// Model parsing (10~60MB) and dance data parsing (vr_*.json up to 2.5MB) do not occupy the main thread,
    /// only lightweight tasks like attaching nodes/creating players return to the main thread — this is the solution to "lag when entering the stage page".
    @MainActor
    func load(character: String, dance: String) async {
        player?.stop(); vroidPlayer?.stop()
        player = nil; vroidPlayer = nil

        let file = characterModelFile(character)
        let loaded = await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(named: file, warmUp: true)
        }.value
        guard let loaded else { NSLog("[DanceStage] failed to load model %@", file); return }
        controller.install(loaded)   // Reuse scene, change model (.scn/.usdz)
        NSLog("[DanceStage] load char=%@ isVRM=%d dance=%@", character, controller.isVRM ? 1 : 0, dance)

        if controller.isVRM {
            // VRoid: Full skeletal animation (quaternion JSON exported by three-vrm retargeting)
            retargeter = nil
            let name = "vr_\(dance)"
            let clip = await Task.detached(priority: .userInitiated) {
                VRoidClip.load(named: name)
            }.value
            guard let clip else { return }
            let p = VRoidClipPlayer(clip: clip, controller: controller)
            vroidPlayer = p
            p.start()
        } else {
            let rt = PoseRetargeter(controller: controller)
            retargeter = rt
            rt.resetCapture()
            let clip = await Task.detached(priority: .userInitiated) {
                Bundle.main.url(forResource: dance, withExtension: "json").flatMap { MocapClip.load($0) }
            }.value
            guard let clip else { return }
            let p = MocapPlayer(frames: clip.frames, retargeter: rt)
            player = p
            p.start()
        }
    }

    /// Re-sample the static pose after switching between Screen and AR.
    func resetRetarget() { retargeter?.resetCapture() }

    func stop() {
        player?.stop(); vroidPlayer?.stop()
    }
}

struct DanceStudioView: View {
    var initialCharacter: String? = nil
    var initialDance: String? = nil
    private let catalog = Catalog.shared
    @Environment(\.dismiss) private var dismiss

    @StateObject private var stage = DanceStage()
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @StateObject private var music = MusicController()
    @StateObject private var localMusic = LocalMusicStore.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var showPaywall = false

    enum Step: Int, CaseIterable { case character, dance, music, perform }
    @State private var step: Step = .character
    @State private var character = ""
    @State private var dance = ""
    @State private var selectedMusic: MusicTrack?
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showAudioDoc = false
    @State private var processing = false   // Mixing music
    @State private var loading = false      // Loading character/dance (model + animation parsing in background)
    @State private var zoomChar: CatalogItem?   // Character zoom preview
    @State private var zoomDance: CatalogItem?  // Dance zoom preview
    @State private var vfx = DanceVFX()         // Stage VFX
    @State private var vfxOn = true
    @State private var vfxPreset = 0

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        ZStack {
            // Bottom background layer, always static, eliminates white flashes
            Color(.systemBackground).ignoresSafeArea()

            if step == .perform {
                // Performance page: Fullscreen immersion, independent layout
                performStep
            } else {
                // Wizard page: Standard Header + Content + Footer structure
                VStack(spacing: 0) {
                    stepHeader
                        .padding(.top, 10)

                    // Content area: Use if/else to ensure stable View identity and prevent layout collapse
                    ZStack {
                        if step == .character {
                            characterStep
                        } else if step == .dance {
                            danceStep
                        } else {
                            musicStep
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider().padding(.horizontal)

                    bottomBar
                        .padding(.top, 12)
                }
            }
        }
        // Use one simple standard animation throughout and drop all the nested withAnimation calls
        .animation(.default, value: step)
        .overlay { if loading { loadingHUD } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // It ships its own unified back/close button
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        .sheet(isPresented: $showAudioDoc) {
            AudioDoc { url in
                if let t = localMusic.importFile(from: url) { select(music: t) }
            }
        }
        .onAppear(perform: setupInitial)
        // Music should only play during "Select Music (audition)" and "Performance": stop it if navigating back to the first two steps,
        // to avoid writing music.stop() at every jump point and potentially missing a path.
        .onChange(of: step) { s in
            if s == .character || s == .dance { music.stop() }
        }
        .onDisappear { music.stop(); vfx.remove(); stage.stop() }
        .fullScreenCover(item: $zoomChar) { c in
            let idx = catalog.characters.firstIndex { $0.key == c.key } ?? 0
            CharacterPreviewPage(key: c.key, name: c.name, style: idx)
        }
        .fullScreenCover(item: $zoomDance) { d in
            let idx = catalog.dances.firstIndex { $0.key == d.key } ?? 0
            DancePreviewPage(dance: d.key, name: d.name, style: idx)
        }
    }

    /// Mask when loading character/dance (model is dozens of MBs, background parsing takes a while, without feedback it might seem stuck).
    private var loadingHUD: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text("Preparing Stage...").font(.footnote).foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: Step header (progress)
    private var stepHeader: some View {
        let titles: [LocalizedStringKey] = ["Select Character", "Select Dance", "Select Music", "Start Performance"]
        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                circleButton(step == .character ? "xmark" : "chevron.left") { back() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(titles[step.rawValue])
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Step \(step.rawValue + 1) of 4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Progress ring or minimalist progress bar
                HStack(spacing: 4) {
                    ForEach(0..<4) { i in
                        Capsule()
                            .fill(i <= step.rawValue ? Color.accentColor : Color.accentColor.opacity(0.2))
                            .frame(width: i == step.rawValue ? 20 : 8, height: 4)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private func circleButton(_ system: String, action: @escaping () -> Void) -> some View {
        CircleButton(system: system, action: action)
    }

    private func back() {
        switch step {
        case .character: dismiss()          // Back from first step = exit studio
        case .dance:     step = .character
        case .music:     step = .dance
        case .perform:                      // Back from performance page = return directly to home, don't return to music selection
            if recorder.isRecording { recorder.stop { _ in } }   // Discard if recording, don't leave the writer hanging
            music.stop(); vfx.remove()
            dismiss()
        }
    }

    // MARK: Step 1 - select character
    private var characterStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                    let isSelected = character == c.key
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            CharacterThumbView(characterKey: c.key, tint: tints[i % tints.count])
                                .aspectRatio(3.0/4.0, contentMode: .fill)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                                .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
                                        radius: isSelected ? 10 : 5, x: 0, y: 5)

                            LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

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

    // Action selection preview: Use currently selected character (fallback model if none selected)
    private var previewModel: String {
        character.isEmpty ? "vroid_preview.usdz" : characterModelFile(character)
    }

    /// Subtitle for each dance (BPM · style), deterministically generated from the name, just for atmosphere.
    private func danceMeta(_ key: String) -> String {
        let styles = ["Pop", "Hip Hop", "House", "Jazz", "K-Pop", "EDM"]
        let hash = abs(key.hashValue)
        let bpm = 96 + (hash % 8) * 8            // 96…152
        return "\(bpm) BPM · \(styles[hash % styles.count])"
    }

    // MARK: Step 2 Select Dance (Each card shows the character striking that pose)
    private var danceStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(Array(catalog.dances.enumerated()), id: \.element.id) { i, d in
                    let isSelected = dance == d.key
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            Group {
                                if isSelected && DeviceTier.allowsLiveDanceCards {
                                    CardBackdrop(style: i)
                                        .overlay(LiveDanceView(model: previewModel, dance: d.key))
                                } else {
                                    DanceThumbView(model: previewModel, dance: d.key, style: i)
                                        .aspectRatio(3.0/4.0, contentMode: .fill)
                                }
                            }
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                            )
                            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
                                    radius: isSelected ? 10 : 5, x: 0, y: 5)

                            LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.name).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                                Text(danceMeta(d.key)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(12)
                        }
                    }
                    .onTapGesture {
                        HapticManager.light()
                        dance = d.key
                    }
                    .overlay(alignment: .topTrailing) {
                        ZoomButton { zoomDance = d }
                            .padding(12)
                            .opacity(isSelected ? 1 : 0.6)
                    }
                }
            }
            .padding(.horizontal).padding(.bottom, 20)
        }
    }

    // MARK: Step 3 - select music
    private var musicStep: some View {
        ScrollView {
            VStack(spacing: 10) {
                musicRow(title: "No Music", system: "speaker.slash", selected: selectedMusic == nil) {
                    selectedMusic = nil; music.stop()
                }
                if !MusicTrack.presets.isEmpty {
                    sectionLabel("Presets")
                    ForEach(MusicTrack.presets) { t in trackRow(t) }
                }
                sectionLabel("Local Music")
                Button { showAudioDoc = true } label: {
                    musicRowLabel(title: "Import from File", system: "plus.circle.fill", selected: false, tint: .accentColor)
                }.buttonStyle(.plain)
                ForEach(localMusic.tracks) { t in trackRow(t) }
            }
            .padding(.horizontal).padding(.bottom, 12)
        }
    }

    private func trackRow(_ t: MusicTrack) -> some View {
        musicRow(title: LocalizedStringKey(t.name), system: "music.note", selected: selectedMusic?.id == t.id) {
            select(music: t)
        }
    }
    private func sectionLabel(_ s: LocalizedStringKey) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6).padding(.leading, 4)
    }
    private func musicRow(title: LocalizedStringKey, system: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { musicRowLabel(title: title, system: system, selected: selected, tint: .accentColor) }
            .buttonStyle(.plain)
    }
    private func musicRowLabel(title: LocalizedStringKey, system: String, selected: Bool, tint: Color) -> some View {
        HStack(spacing: 16) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(selected ? .white : tint)
                .frame(width: 44, height: 44)
                .background(selected ? tint : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.system(size: 16, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))

            Spacer()

            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(selected ? tint.opacity(0.08) : Color.clear)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? tint : Color.clear, lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 5, y: 2)
    }

    // MARK: Step 4 - perform
    private var performStep: some View {
        ZStack {
            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller, onAttach: { stage.resetRetarget() }, holder: holder)
                } else {
                    CharacterSceneView(controller: stage.controller, onAttach: { stage.resetRetarget() }, holder: holder)
                }
            }
            .id(arMode)
            .ignoresSafeArea()

            // AR guidance: when AR mode is on but no plane has been detected or placement made yet, show the guide
            if arMode {
                ARCoachView()
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                HStack {
                    circleButton("chevron.left") { back() }
                    Spacer()
                    Picker("", selection: $arMode) { Text("Screen").tag(false); Text("AR").tag(true) }
                        .pickerStyle(.segmented).frame(width: 120)
                }
                .padding(.horizontal, 12).padding(.top, 6)

                Spacer()

                VStack(spacing: 14) {
                    sceneSelectionBar
                    vfxBar
                    recordButton.padding(.top, 2)
                }
                .padding(.top, 26).padding(.bottom, 26)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
    }

    // Scene selection bar: Studio vs Sky
    private var sceneSelectionBar: some View {
        HStack(spacing: 12) {
            sceneChip(type: .studio, title: "Studio", icon: "house.fill")
            sceneChip(type: .sky, title: "Sky", icon: "cloud.sun.fill")
        }
        .padding(.bottom, 10)
    }

    private func sceneChip(type: CharacterSceneController.BackgroundType, title: LocalizedStringKey, icon: String) -> some View {
        let on = stage.controller.backgroundType == type
        return Button {
            stage.controller.backgroundType = type
            stage.objectWillChange.send() // Force UI refresh to update button state
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background {
                if on {
                    Color.white
                } else {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // Bottom VFX selection bar (referencing camera products: horizontal chips + large record button in the middle)
    private var vfxBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                vfxChip(title: "Off", icon: "nosign", on: !vfxOn) { vfxOn = false; installVFX() }
                ForEach(Array(VFXPreset.all.enumerated()), id: \.offset) { i, p in
                    vfxChip(title: LocalizedStringKey(p.name), icon: "sparkles", on: vfxOn && vfxPreset == i) {
                        vfxOn = true; vfxPreset = i; installVFX()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func vfxChip(title: LocalizedStringKey, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background {
                if on {
                    Color.white
                } else {
                    Color.clear.background(.ultraThinMaterial)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                HapticManager.medium()
                recorder.stop { url in
                    guard let url else { return }
                    let watermark = !ProStore.shared.isPro
                    // Has music or needs watermark -> proceed to export; otherwise save directly
                    if selectedMusic != nil || watermark {
                        processing = true
                        Task {
                            let final = await VideoAudioMixer.export(video: url, audio: selectedMusic?.url,
                                                                     watermark: watermark) ?? url
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

    // MARK: Bottom primary button
    private var bottomBar: some View {
        Button(action: next) {
            HStack(spacing: 8) {
                Text(loading ? "Preparing assets…" : (step == .music ? "Start Performance" : "Next"))
                if !loading {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background {
                if nextEnabled {
                    LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                } else {
                    Color(.systemGray4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: nextEnabled ? Color.accentColor.opacity(0.3) : .clear, radius: 10, y: 5)
        }
        .disabled(!nextEnabled)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var nextEnabled: Bool {
        if loading { return false }
        switch step {
        case .character: return !character.isEmpty
        case .dance:     return !dance.isEmpty
        default:         return true
        }
    }

    // MARK: Logic
    private func setupInitial() {
        if let ic = initialCharacter, catalog.characters.contains(where: { $0.key == ic }) { character = ic }
        if let id = initialDance, catalog.dances.contains(where: { $0.key == id }) { dance = id }
        // Brought in a character from the library -> go directly to dance selection, and select the first dance by default
        if !character.isEmpty && initialCharacter != nil { step = .dance; ensureDefaultDance() }
    }

    /// When entering dance selection, if none is selected, default to the first one.
    private func ensureDefaultDance() {
        if dance.isEmpty { dance = catalog.dances.first?.key ?? "" }
    }

    private func next() {
        HapticManager.medium()
        switch step {
        case .character: step = .dance; ensureDefaultDance()
        case .dance:     step = .music
        case .music:     startPerform()
        case .perform:   break
        }
    }

    private func startPerform() {
        guard !loading else { return }
        loading = true
        let ch = character, dc = dance
        Task {
            await stage.load(character: ch, dance: dc)
            loading = false
            if let m = selectedMusic { music.play(m) } else { music.stop() }
            step = .perform
            installVFX()
        }
    }

    /// Install/refresh stage VFX (attach to character screen scene, read music energy pulses).
    private func installVFX() {
        // The stage lights read the same energy as the particles, so beams, floor pool and
        // confetti all hit on the same beat. Set here because this runs on every VFX change.
        stage.controller.levelProvider = { [weak music] in music?.currentLevel() ?? 0 }
        vfx.remove()
        let cam = stage.controller.cameraNode?.camera
        guard vfxOn else { cam?.bloomIntensity = 0; return }
        // Bloom post-processing: Only let ultra-bright glowing particles produce a soft halo (high threshold to avoid overexposing character's white clothes)
        // Disable bloom on low-end devices (DeviceTier) to eliminate lag from fullscreen Gaussian blur.
        // The camera tone-maps now (wantsHDR), so a 0.92 threshold caught the character's own
        // white clothing and wrapped them in a glow. Only the VFX particles should bloom.
        cam?.bloomIntensity = DeviceTier.bloomIntensity * 0.55
        cam?.bloomThreshold = 1.15
        cam?.bloomBlurRadius = 14
        vfx.preset = vfxPreset
        vfx.install(in: stage.controller.scene,
                    feetY: stage.controller.feetY,
                    height: stage.controller.modelHeight,
                    level: { [weak music] in music?.currentLevel() ?? 0 })
    }

    private func select(music track: MusicTrack) {
        HapticManager.selection()
        selectedMusic = track
        music.play(track)   // Audition
    }
}

/// AR coaching component: Displayed when the user has not placed the character.
struct ARCoachView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    .frame(width: 80, height: 80)

                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .offset(x: isAnimating ? 15 : -15)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
            }

            VStack(spacing: 8) {
                Text("Scan Your Space")
                    .font(.headline)
                Text("Slowly move your phone to find a flat floor")
                    .font(.subheadline)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)

            Text("Tap on floor to place character")
                .font(.caption.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 10)
        }
        .padding(.vertical, 40)
        .background(
            RadialGradient(colors: [.black.opacity(0.4), .clear], center: .center, startRadius: 0, endRadius: 300)
        )
        .onAppear { isAnimating = true }
    }
}
