//
//  DanceStudioView.swift
//  Animo3D
//
//  舞蹈工作室：选角色 + 选舞蹈 → 角色跳起来。
//  角色 .scn 与舞蹈 .json 均来自 App 包，清单由 manifest.json 描述（后续可换成网络下载）。
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

    static func load() -> Catalog {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return Catalog(characters: [], dances: [])
        }
        return c
    }
}

/// 管理当前角色 + 播放的舞蹈。
final class DanceStage: ObservableObject {
    let controller = CharacterSceneController()   // 单一实例，原地换模型
    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?

    func load(character: String, dance: String) {
        player?.stop()
        _ = controller.loadModel(named: "\(character).scn")   // 复用场景，换模型
        retargeter = PoseRetargeter(controller: controller)
        playDance(dance)
    }

    /// 屏幕↔AR 切换后重新采样静止姿态。
    func resetRetarget() { retargeter?.resetCapture() }

    func playDance(_ dance: String) {
        guard let rt = retargeter else { return }
        player?.stop()
        rt.resetCapture()
        guard let url = Bundle.main.url(forResource: dance, withExtension: "json"),
              let clip = MocapClip.load(url) else { return }
        let p = MocapPlayer(frames: clip.frames, retargeter: rt)
        player = p
        p.start()
    }
}

struct DanceStudioView: View {
    var initialCharacter: String? = nil
    var initialDance: String? = nil
    private let catalog = Catalog.load()
    @Environment(\.dismiss) private var dismiss

    @StateObject private var stage = DanceStage()
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @StateObject private var music = MusicController()
    @StateObject private var localMusic = LocalMusicStore.shared

    enum Step: Int, CaseIterable { case character, dance, music, perform }
    @State private var step: Step = .character
    @State private var character = ""
    @State private var dance = ""
    @State private var selectedMusic: MusicTrack?
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var showAudioDoc = false
    @State private var processing = false   // 合成音乐中

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        VStack(spacing: 0) {
            if step != .perform { stepHeader }

            switch step {
            case .character: characterStep
            case .dance:     danceStep
            case .music:     musicStep
            case .perform:   performStep
            }

            if step != .perform { bottomBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // 自带统一的返回/关闭按钮
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        .sheet(isPresented: $showAudioDoc) {
            AudioDoc { url in
                if let t = localMusic.importFile(from: url) { select(music: t) }
            }
        }
        .onAppear(perform: setupInitial)
        .onDisappear { music.stop() }
    }

    // MARK: 步骤头部（进度）
    private var stepHeader: some View {
        let titles = ["选角色", "选舞蹈", "选音乐", "表演"]
        return VStack(spacing: 10) {
            ZStack {
                Text(titles[step.rawValue]).font(.headline)
                HStack {
                    circleButton(step == .character ? "xmark" : "chevron.left") { back() }
                    Spacer()
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i <= step.rawValue ? Color.accentColor : Color(.systemGray4))
                        .frame(width: i == step.rawValue ? 22 : 8, height: 6)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 12)
    }

    private func circleButton(_ system: String, action: @escaping () -> Void) -> some View {
        CircleButton(system: system, action: action)
    }

    private func back() {
        switch step {
        case .character: dismiss()          // 第一步返回=退出工作室
        case .dance:     step = .character
        case .music:     step = .dance
        case .perform:   step = .music; music.stop()
        }
    }

    // MARK: 步骤1 选角色
    private var characterStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(catalog.characters.enumerated()), id: \.element.id) { i, c in
                    ZStack(alignment: .bottomLeading) {
                        CharacterThumbView(characterKey: c.key, tint: tints[i % tints.count])
                            .aspectRatio(3.0/4.0, contentMode: .fill)
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                        Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).padding(10)
                    }
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: character == c.key ? 3 : 0))
                    .onTapGesture { character = c.key }
                }
            }
            .padding(.horizontal).padding(.bottom, 12)
        }
    }

    // 选动作预览用的女孩模型
    private let previewModel = "vroid_preview.usdz"

    /// 每支舞的副标题（BPM · 风格），由名字确定性生成,仅作展示氛围。
    private func danceMeta(_ key: String) -> String {
        let styles = ["Pop", "Hip Hop", "House", "Jazz", "K-Pop", "EDM"]
        let hash = abs(key.hashValue)
        let bpm = 96 + (hash % 8) * 8            // 96…152
        return "\(bpm) BPM · \(styles[hash % styles.count])"
    }

    // MARK: 步骤2 选舞蹈（每张卡展示女孩摆出该动作）
    private var danceStep: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(Array(catalog.dances.enumerated()), id: \.element.id) { i, d in
                    ZStack(alignment: .bottomLeading) {
                        if dance == d.key {
                            // 选中的卡片：实时跳动（同样用装饰背景）
                            CardBackdrop(style: i).overlay(LiveDanceView(model: previewModel, dance: d.key))
                        } else {
                            DanceThumbView(model: previewModel, dance: d.key, style: i)
                                .aspectRatio(3.0/4.0, contentMode: .fill)
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            Text(danceMeta(d.key)).font(.caption2).foregroundStyle(.white.opacity(0.85))
                        }
                        .padding(10)
                    }
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor, lineWidth: dance == d.key ? 3 : 0))
                    .onTapGesture { dance = d.key }
                }
            }
            .padding(.horizontal).padding(.bottom, 12)
        }
    }

    // MARK: 步骤3 选音乐
    private var musicStep: some View {
        ScrollView {
            VStack(spacing: 10) {
                musicRow(title: "不用音乐", system: "speaker.slash", selected: selectedMusic == nil) {
                    selectedMusic = nil; music.stop()
                }
                if !MusicTrack.presets.isEmpty {
                    sectionLabel("内置音乐")
                    ForEach(MusicTrack.presets) { t in trackRow(t) }
                }
                sectionLabel("本地音乐")
                Button { showAudioDoc = true } label: {
                    musicRowLabel(title: "从文件导入", system: "plus.circle.fill", selected: false, tint: .accentColor)
                }.buttonStyle(.plain)
                ForEach(localMusic.tracks) { t in trackRow(t) }
            }
            .padding(.horizontal).padding(.bottom, 12)
        }
    }

    private func trackRow(_ t: MusicTrack) -> some View {
        musicRow(title: t.name, system: "music.note", selected: selectedMusic?.id == t.id) {
            select(music: t)
        }
    }
    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6).padding(.leading, 4)
    }
    private func musicRow(title: String, system: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { musicRowLabel(title: title, system: system, selected: selected, tint: .accentColor) }
            .buttonStyle(.plain)
    }
    private func musicRowLabel(title: String, system: String, selected: Bool, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: system).foregroundStyle(tint).frame(width: 24)
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 步骤4 表演
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
            .ignoresSafeArea()   // 沉浸式：铺满到顶部/底部

            VStack {
                HStack {
                    circleButton("chevron.left") { back() }
                    Spacer()
                    Picker("", selection: $arMode) { Text("屏幕").tag(false); Text("AR").tag(true) }
                        .pickerStyle(.segmented).frame(width: 130)
                }
                Spacer()
                recordButton.padding(.bottom, 24)
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop { url in
                    guard let url else { return }
                    if let track = selectedMusic {
                        // 有背景音乐 → 合成进视频再保存
                        processing = true
                        Task {
                            let final = await VideoAudioMixer.mix(video: url, audio: track.url) ?? url
                            await MainActor.run {
                                processing = false
                                if let saved = WorksStore.shared.add(from: final) { shareURL = saved; showShare = true }
                            }
                        }
                    } else if let saved = WorksStore.shared.add(from: url) {
                        shareURL = saved; showShare = true
                    }
                }
            } else if let v = holder.scnView { recorder.start(view: v) }
        } label: {
            Group {
                if processing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(recorder.isRecording ? .red : .white)
                }
            }
            .frame(width: 62, height: 62)
            .background(.black.opacity(0.35), in: Circle())
        }
        .disabled(processing)
    }

    // MARK: 底部主按钮
    private var bottomBar: some View {
        Button(action: next) {
            Text(step == .music ? "开始跳舞" : "下一步")
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(nextEnabled ? Color.accentColor : Color(.systemGray3), in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(!nextEnabled)
        .padding(.horizontal).padding(.bottom, 8)
    }

    private var nextEnabled: Bool {
        switch step {
        case .character: return !character.isEmpty
        case .dance:     return !dance.isEmpty
        default:         return true
        }
    }

    // MARK: 逻辑
    private func setupInitial() {
        if let ic = initialCharacter, catalog.characters.contains(where: { $0.key == ic }) { character = ic }
        if let id = initialDance, catalog.dances.contains(where: { $0.key == id }) { dance = id }
        // 从角色库带入角色 → 直接到选舞蹈；从热门舞蹈带入 → 仍从选角色开始
        if !character.isEmpty && initialCharacter != nil { step = .dance }
    }

    private func next() {
        switch step {
        case .character: step = .dance
        case .dance:     step = .music
        case .music:     startPerform()
        case .perform:   break
        }
    }

    private func startPerform() {
        stage.load(character: character, dance: dance)
        if let m = selectedMusic { music.play(m) } else { music.stop() }
        step = .perform
    }

    private func select(music track: MusicTrack) {
        selectedMusic = track
        music.play(track)   // 试听
    }
}
