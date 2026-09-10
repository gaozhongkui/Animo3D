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

/// Manage the current character + the dance being played.
struct DanceStudioView: View {
    var initialCharacter: String? = nil
    var initialDance: String? = nil
    @ObservedObject private var remoteAssets = RemoteAssets.shared
    @Environment(\.dismiss) private var dismiss

    @StateObject private var stage = DancePerformer(owner: "DanceStage", groundEnabled: true)
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
    /// The placed AR container, and whether placement has happened. Effects hang off the container
    /// and the placement guidance comes down once it exists.
    @State private var arContainer: SCNNode?
    @State private var arPlaced = false
    /// Read once, at init, so the panel does not vanish mid-session the moment the flag is written.
    @State private var showCoach = !ARCoachView.hasBeenSeen
    /// True while Apple's scanning overlay owns the screen.
    @State private var arCoaching = false
    @State private var arTrackingHint: String?
    @State private var showPlacementMiss = false
    @State private var placementMissTask: Task<Void, Never>?
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var finished: FinishedWork?      // Completion page after a recording
    @State private var showAudioDoc = false
    @State private var processing = false   // Mixing music
    /// When the current take started, so `record_finished` can carry its length.
    @State private var recordStartedAt: Date?
    /// When Start Performance was pressed, so `stage_ready` can carry how long the user waited for
    /// the first frame. That wait is a download plus a scene build, and it is the one place this
    /// app can lose somebody who has already decided they want the video.
    @State private var performStartedAt: CFAbsoluteTime = 0
    /// When AR was entered, so `ar_plane_found` can say how long the room took.
    @State private var arEnteredAt: CFAbsoluteTime = 0
    @State private var loading = false      // Loading character/dance (model + animation parsing in background)
    @State private var stageWatchdog: Task<Void, Never>?
    @State private var vfx = DanceVFX()         // Stage VFX
    /// Effects default on where they are available at all - on low-end the row is hidden and
    /// installVFX() refuses, so this staying true there would be a selection nothing can act on.
    @State private var vfxOn = DeviceTier.allowsStageVFX
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
        .overlay { if loading { StageLoadingHUD(progress: remoteAssets.activeDownloadProgress) } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // It ships its own unified back/close button
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        // Recording used to end on a bare share sheet, with nothing saying the clip had been kept.
        .fullScreenCover(item: $finished) { work in
            WorkDetailView(url: work.url, justSaved: true) { finished = nil }
        }
        .sheet(isPresented: $showAudioDoc) {
            AudioDoc { url in
                if let t = localMusic.importFile(from: url) { select(music: t) }
            }
        }
        .onAppear(perform: setupInitial)
        // Music should only play during "Select Music (audition)" and "Performance": stop it if navigating back to the first two steps,
        // to avoid writing music.stop() at every jump point and potentially missing a path.
        .onChange(of: arMode) { _ in
            arContainer = nil
            arPlaced = false
            vfx.remove()
        }
        .onChange(of: step) { s in
            if s == .character || s == .dance { music.stop() }
            // The four-step wizard is the activation funnel. One event with the step as a
            // parameter, so it reads in order rather than as four counts nobody can line up.
            Track.log(.studioStep, ["step": String(describing: s)])
            // Parse the model while the user is still browsing dances and music. By the time they
            // press Start Performance the scene is already built, so the button has nothing to wait on.
            if s == .dance || s == .music { stage.prewarm(character: character) }
        }
        .onChange(of: dance) { d in
            // The grid only shows pre-rendered art; pull the full take now.
            stage.prewarm(dance: d)
        }
        .onDisappear {
            music.stop(); vfx.remove(); stage.stop()
            // Leaving before performing is the drop-off. Step counts alone cannot separate "went
            // back a step" from "gave up here"; this can.
            if step != .perform { Track.log(.studioAbandoned, ["step": String(describing: step)]) }
        }
        .trackScreen("Studio_\(String(describing: step))")
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
                    Text(String(format: L("Step %lld of 4"), step.rawValue + 1))
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
                ForEach(Array(remoteAssets.characters.enumerated()), id: \.element.id) { i, c in
                    let isSelected = character == c.id
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            CharacterThumbView(characterKey: c.id, tint: tints[i % tints.count])
                                .aspectRatio(3.0/4.0, contentMode: .fill)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                                .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : Color.black.opacity(0.05),
                                        radius: isSelected ? 10 : 5, x: 0, y: 5)

                            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                           startPoint: .init(x: 0.5, y: 0.55), endPoint: .bottom)
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
                        character = c.id
                        Track.log(.characterSelected, ["character": c.id])
                    }
                }
            }
            // Top padding is not decoration: a card's selection stroke, its shadow and (on the
            // dance grid) its 1.03 scale all extend past its own bounds, and with the grid flush
            // against the scroll view's top edge the first row had all three clipped off.
            .padding(.horizontal).padding(.top, 12).padding(.bottom, 20)
        }
    }

    /// Who performs the live preview on the selected card: the chosen character, or the built-in
    /// one before a choice has been made.
    private var previewCharacter: String {
        character.isEmpty ? BuiltInAssets.characterId : character
    }

    /// Subtitle for a dance card: how long the take actually runs.
    ///
    /// This used to read "128 BPM · House", made up from `key.hashValue`. Two problems. It was
    /// invented data presented as fact - nothing in the catalog knows a dance's BPM or genre. And
    /// `hashValue` is seeded per process in Swift, so the comment claiming it was deterministic was
    /// wrong: every launch gave the same dance a different tempo and a different genre. The index
    /// carries the real duration, so show that.
    private func danceMeta(_ d: DanceItem) -> String {
        guard let seconds = d.duration, seconds > 0 else { return "Ready to dance" }
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Step 2 - select dance (cards are pre-rendered art, see DanceThumb)
    private var danceStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach(Array(remoteAssets.dances.enumerated()), id: \.element.id) { i, d in
                    let isSelected = dance == d.id
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .bottomLeading) {
                            Group {
                                if isSelected && DeviceTier.allowsLiveDanceCards {
                                    CardBackdrop(style: i)
                                        .overlay(LiveDanceView(character: previewCharacter, dance: d.id))
                                } else {
                                    DanceCardView(character: previewCharacter, dance: d.id, style: i)
                                        .aspectRatio(3.0/4.0, contentMode: .fill)
                                }
                            }
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(isSelected ? CardBackdrop.accent(for: i).opacity(0.95)
                                                       : .white.opacity(0.08),
                                            lineWidth: isSelected ? 2 : 0.5)
                            )
                            // Selection reads as stage light, not as a form control: the card lifts
                            // and glows, in its own accent rather than the system blue.
                            .shadow(color: isSelected ? CardBackdrop.accent(for: i).opacity(0.6)
                                                      : .black.opacity(0.35),
                                    radius: isSelected ? 18 : 8, x: 0, y: isSelected ? 8 : 4)
                            .scaleEffect(isSelected ? 1.03 : 1)
                            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: isSelected)

                            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                           startPoint: .init(x: 0.5, y: 0.55), endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                // Two lines: "Booty Hip Hop Dance" and "Dancing Maraschino Step" do
                                // not fit on one at this size, and a truncated dance name is the
                                // one thing on this card the user is actually reading.
                                Text(d.name)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(danceMeta(d)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(12)
                        }
                    }
                    .onTapGesture {
                        HapticManager.light()
                        dance = d.id
                        Track.log(.danceSelected, ["dance": d.id, "character": character])
                    }
                }
            }
            // Top padding is not decoration: a card's selection stroke, its shadow and (on the
            // dance grid) its 1.03 scale all extend past its own bounds, and with the grid flush
            // against the scroll view's top edge the first row had all three clipped off.
            .padding(.horizontal).padding(.top, 12).padding(.bottom, 20)
        }
    }

    // MARK: Step 3 - select music
    private var musicStep: some View {
        ScrollView {
            VStack(spacing: 10) {
                musicRow(title: "No Music", system: "speaker.slash", selected: selectedMusic == nil) {
                    selectedMusic = nil; music.stop()
                    Track.log(.musicSelected, ["music": "none"])
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
    /// The coaching panel goes away on the user's first tap - hit or miss - and does not come back
    /// in later sessions. A tap is proof the instruction was read; leaving the panel up until
    /// placement succeeds meant it stayed longest exactly when placement was failing.
    private func retireCoach() {
        ARCoachView.hasBeenSeen = true
        guard showCoach else { return }
        withAnimation(.easeOut(duration: 0.25)) { showCoach = false }
    }

    private var performStep: some View {
        ZStack {
            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller,
                                    onAttach: { stage.rebaseRetarget(); stageDidRender() },
                                    onPlaced: { node in
                                        arContainer = node
                                        arPlaced = true
                                        Track.log(.arPlaced, ["character": character, "dance": dance,
                                                              "ms": arEnteredAt > 0 ? Track.ms(since: arEnteredAt) : 0])
                                        retireCoach()
                                        installVFX()      // effects only exist once there is somewhere to put them
                                    },
                                    onPlacementMissed: {
                                        retireCoach(); flashPlacementMiss()
                                        Track.log(.arPlaceMissed, ["character": character])
                                    },
                                    onRelocated: { stage.rebaseRetarget() },
                                    onCoaching: { arCoaching = $0 },
                                    onTrackingHint: { arTrackingHint = $0 },
                                    holder: holder)
                } else {
                    CharacterSceneView(controller: stage.controller,
                                       onAttach: { stage.rebaseRetarget() },
                                       onFirstFrame: { stageDidRender() },
                                       holder: holder)
                }
            }
            .id(arMode)
            .ignoresSafeArea()

            // Placement guidance, up only until the character is standing. The condition used to be
            // just `arMode`, so this panel sat over the camera feed for the whole session.
            // Own guidance only once Apple's is done: the overlay covers scanning, this covers
            // the tap that places the character.
            if arMode && !arPlaced && showCoach && !arCoaching {
                ARCoachView()
                    .transition(.opacity)
            }

            if let arTrackingHint, arMode, !arPlaced, !arCoaching {
                VStack {
                    Spacer()
                    Text(arTrackingHint)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.horizontal, 32)
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            // A tap that found no floor used to do nothing at all except print to the console. This
            // is the answer to it: brief, centred low so it does not cover the reticle.
            if arMode && showPlacementMiss {
                VStack {
                    Spacer()
                    Text("Point at the floor, then tap")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                HStack {
                    circleButton("chevron.left") { back() }
                        .opacity(recorder.isRecording ? 0 : 1) // hidden while recording
                    Spacer()
                    Picker("", selection: $arMode) { Text("Screen").tag(false); Text("AR").tag(true) }
                        .pickerStyle(.segmented).frame(width: 120)
                        .opacity(recorder.isRecording ? 0 : 1) // hidden while recording
                        .onChange(of: arMode) { on in
                            if on {
                                arEnteredAt = CFAbsoluteTimeGetCurrent()
                                Track.log(.arEntered, ["character": character, "dance": dance])
                            } else if arEnteredAt > 0 {
                                // Whether the room ever gave us somewhere to stand is the number
                                // that says AR failed, and it is only knowable on the way out.
                                Track.log(.arAbandoned, ["placed": arPlaced ? "yes" : "no",
                                                         "seconds": Int(CFAbsoluteTimeGetCurrent() - arEnteredAt)])
                                arEnteredAt = 0
                            }
                        }
                }
                .padding(.horizontal, 12).padding(.top, 6)

                Spacer()

                VStack(spacing: 14) {
                    // No scene picker: the club stage was removed from the product, so there is one
                    // scene and nothing to choose between.
                    if DeviceTier.allowsStageVFX {
                        vfxBar
                            .opacity(recorder.isRecording ? 0 : 1) // hidden while recording
                    }

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
                let seconds = recordStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
                recordStartedAt = nil
                recorder.stop { url in
                    Track.log(.recordFinished, ["character": character, "dance": dance,
                                                "mode": arMode ? "ar" : "screen",
                                                "seconds": seconds,
                                                "ok": url == nil ? "no" : "yes"])
                    guard let url else { return }
                    // The watermark is already in the frames, so only music still needs an export pass.
                    if let audio = selectedMusic?.url {
                        processing = true
                        Task {
                            let exportStart = CFAbsoluteTimeGetCurrent()
                            let final = await VideoAudioMixer.export(video: url, audio: audio) ?? url
                            await MainActor.run {
                                Track.log(.exportFinished, ["ms": Track.ms(since: exportStart),
                                                            "ok": final == url ? "no" : "yes"])
                                HapticManager.success()
                                processing = false
                                if let saved = WorksStore.shared.add(from: final) {
                                    Track.log(.workSaved, ["music": "yes"])
                                    finished = FinishedWork(url: saved)
                                }
                            }
                        }
                    } else if let saved = WorksStore.shared.add(from: url) {
                        Track.log(.workSaved, ["music": "no"])
                        HapticManager.success()
                        finished = FinishedWork(url: saved)
                    }
                }
            } else if let v = holder.scnView {
                HapticManager.medium()
                recordStartedAt = Date()
                Track.log(.recordStarted, ["character": character, "dance": dance,
                                           "mode": arMode ? "ar" : "screen",
                                           "plan": pro.isPro ? "pro" : "free"])
                recorder.start(view: v, watermark: pro.isPro ? nil : "Livo 3D")
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
        .onChange(of: recorder.isRecording) { recording in
            // The camera move runs the whole time now, in preview as well as in the recording, so
            // the user is not surprised by motion that only appears in the exported clip. All this
            // does is restart the swing from the current framing when a take begins, so a recording
            // opens on the shot rather than halfway through a drift.
            if recording { stage.controller.resetCameraMove() }
        }
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

    /// Show the "point at the floor" hint for a moment. Retapping restarts the timer rather than
    /// stacking hints.
    private func flashPlacementMiss() {
        HapticManager.light()
        placementMissTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showPlacementMiss = true }
        placementMissTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showPlacementMiss = false }
        }
    }

    // MARK: Logic
    private func setupInitial() {
        if let ic = initialCharacter, remoteAssets.characters.contains(where: { $0.id == ic }) { character = ic }
        if let id = initialDance, remoteAssets.dances.contains(where: { $0.id == id }) { dance = id }
        // Brought in a character from the library -> go directly to dance selection, and select the first dance by default
        if !character.isEmpty && initialCharacter != nil { step = .dance; ensureDefaultDance() }
    }

    /// When entering dance selection, if none is selected, default to the first one.
    private func ensureDefaultDance() {
        guard dance.isEmpty else { return }
        // Prefer the bundled dance: it plays with no network at all.
        dance = remoteAssets.dances.first { $0.id == BuiltInAssets.danceId }?.id
            ?? remoteAssets.dances.first?.id ?? ""
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
        performStartedAt = CFAbsoluteTimeGetCurrent()
        let ch = character, dc = dance
        Task {
            guard await stage.load(character: ch, dance: dc) else { loading = false; return }
            if let m = selectedMusic { music.play(m) } else { music.stop() }
            Track.log(.performanceStarted, ["character": ch, "dance": dc,
                                            "music": selectedMusic?.name ?? "none",
                                            "mode": arMode ? "ar" : "screen"])
            step = .perform
            installVFX()
            // The mask deliberately stays up past this point. Switching to .perform is when the
            // SCNView is first built - floor, reflection, shadow map, stage rig and particles all
            // assembled synchronously - and the first frame still has to reach the screen. Dropping
            // the mask on "parsing finished" is what left the user looking at an empty stage.
            // CharacterSceneView.onFirstFrame takes it down; the watchdog is there so a stage that
            // never renders cannot strand the user behind a permanent mask.
            stageWatchdog?.cancel()
            stageWatchdog = Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                NSLog("[Stage] first frame never arrived; dropping the mask anyway")
                loading = false
            }
        }
    }

    private func stageDidRender() {
        stageWatchdog?.cancel()
        stageWatchdog = nil
        // Only the first frame of a performance counts; this also fires when AR re-attaches.
        if performStartedAt > 0 {
            Track.log(.stageReady, ["character": character, "dance": dance,
                                    "ms": Track.ms(since: performStartedAt)])
            performStartedAt = 0
        }
        loading = false
    }

    /// Install/refresh stage VFX (attach to character screen scene, read music energy pulses).
    private func installVFX() {
        // The stage lights read the same energy as the particles, so beams, floor pool and
        // confetti all hit on the same beat. Set here because this runs on every VFX change.
        stage.controller.levelProvider = { [weak music] in music?.currentLevel() ?? 0 }
        vfx.remove()
        // No chips on low-end, so nothing to install - and nothing should sneak in through a
        // restored selection either.
        guard DeviceTier.allowsStageVFX else {
            (arMode ? holder.scnView?.pointOfView?.camera : stage.controller.cameraNode?.camera)?
                .bloomIntensity = 0
            return
        }
        // AR renders through ARKit's own camera and its own scene, so both the bloom target and the
        // parent node differ from the screen stage. Pointing either at the controller was why the
        // effect chips changed state but nothing appeared in AR.
        let cam = arMode ? holder.scnView?.pointOfView?.camera : stage.controller.cameraNode?.camera
        guard vfxOn else { cam?.bloomIntensity = 0; return }
        // Bloom post-processing: Only let ultra-bright glowing particles produce a soft halo (high threshold to avoid overexposing character's white clothes)
        // Disable bloom on low-end devices (DeviceTier) to eliminate lag from fullscreen Gaussian blur.
        // The camera tone-maps now (wantsHDR), so a 0.92 threshold caught the character's own
        // white clothing and wrapped them in a glow. Only the VFX particles should bloom.
        cam?.bloomIntensity = DeviceTier.bloomIntensity * 0.55
        cam?.bloomThreshold = 1.15
        cam?.bloomBlurRadius = 14
        vfx.preset = vfxPreset
        // In AR the container already sits the character's feet on its own origin, so the effects
        // start at 0 there and ride the anchor's scale.
        let parent = arMode ? arContainer : stage.controller.scene.rootNode
        guard let parent else { return }        // AR, nothing placed yet - installed again on placement
        vfx.install(in: parent,
                    feetY: arMode ? 0 : stage.controller.feetY,
                    height: stage.controller.modelHeight,
                    level: { [weak music] in music?.currentLevel() ?? 0 })
    }

    private func select(music track: MusicTrack) {
        HapticManager.selection()
        selectedMusic = track
        music.play(track)   // Audition
        Track.log(.musicSelected, ["music": track.name])
    }
}

/// AR coaching component: Displayed when the user has not placed the character.
struct ARCoachView: View {
    /// Shown on the first AR session and then never again.
    ///
    /// It explains a gesture - aim at the floor, tap - which is the kind of thing a person needs
    /// told once. Showing it on every entry means the panel is in the way of the shot for everyone
    /// who already knows, and it is the single largest thing on screen.
    private static let seenKey = "ar_coach_seen"
    static var hasBeenSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

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
        // Nothing here is interactive, and this panel sits dead centre - exactly where the reticle
        // is and where the user aims to place the character. A SwiftUI background is hit-testable
        // across its whole rect even where it is fully transparent, so it was swallowing every
        // placement tap before it could reach the ARSCNView underneath: the character could never
        // be placed, and the panel it blocked only goes away once the character *is* placed.
        .allowsHitTesting(false)
        .onAppear { isAnimating = true }
    }
}
