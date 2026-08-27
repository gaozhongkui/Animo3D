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

    /// manifest.json 是只读的静态清单,全局解析一次即可。
    /// 以前写成 View 的存储属性,SwiftUI 每次重建 struct 都要重读重解一遍。
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

/// 管理当前角色 + 播放的舞蹈。
final class DanceStage: ObservableObject {
    let controller: CharacterSceneController = {
        let c = CharacterSceneController()
        c.groundEnabled = true   // 表演页显示地面+阴影
        return c
    }()
    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var vroidPlayer: VRoidClipPlayer?

    /// 加载角色 + 舞蹈。**重活全在后台线程**：
    /// 模型解析(10~60MB)与舞蹈数据解析(vr_*.json 最大 2.5MB)都不占主线程,
    /// 只有挂节点/建播放器这点轻活回主线程 —— 这是"进舞台页卡一下"的正解。
    @MainActor
    func load(character: String, dance: String) async {
        player?.stop(); vroidPlayer?.stop()
        player = nil; vroidPlayer = nil

        let file = characterModelFile(character)
        let loaded = await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(named: file, warmUp: true)
        }.value
        guard let loaded else { NSLog("[DanceStage] 模型加载失败 %@", file); return }
        controller.install(loaded)   // 复用场景，换模型(.scn/.usdz)
        NSLog("[DanceStage] load char=%@ isVRM=%d dance=%@", character, controller.isVRM ? 1 : 0, dance)

        if controller.isVRM {
            // VRoid：完整骨骼动画(three-vrm 重定向导出的四元数 JSON)
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

    /// 屏幕↔AR 切换后重新采样静止姿态。
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
    @State private var processing = false   // 合成音乐中
    @State private var loading = false      // 加载角色/舞蹈中(模型+动画在后台解析)
    @State private var zoomChar: CatalogItem?   // 角色放大预览
    @State private var zoomDance: CatalogItem?  // 舞蹈放大预览
    @State private var vfx = DanceVFX()         // 舞台特效
    @State private var vfxOn = true
    @State private var vfxPreset = 0

    private let tints: [Color] = [.blue, .pink, .purple, .orange, .teal, .indigo, .green, .red]

    var body: some View {
        ZStack {
            // 最底层背景，永远静止，消除白闪
            Color(.systemBackground).ignoresSafeArea()

            if step == .perform {
                // 表演页：全屏沉浸，独立布局
                performStep
            } else {
                // 向导页：标准的 页眉 + 内容 + 页脚 结构
                VStack(spacing: 0) {
                    stepHeader
                        .padding(.top, 10)

                    // 内容区：使用 if/else 保证视图 Identity 稳定，防止布局崩塌
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
        // 统一使用一个简单的标准动画，移除所有嵌套的 withAnimation
        .animation(.default, value: step)
        .overlay { if loading { loadingHUD } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)   // 自带统一的返回/关闭按钮
        .sheet(isPresented: $showShare) { if let url = shareURL { ShareSheet(items: [url]) } }
        .sheet(isPresented: $showAudioDoc) {
            AudioDoc { url in
                if let t = localMusic.importFile(from: url) { select(music: t) }
            }
        }
        .onAppear(perform: setupInitial)
        // 音乐只该在「选音乐(试听)」和「表演」时响：任何路径退回前两步都收掉,
        // 避免每个跳转点各写一遍 music.stop() 漏掉某条路。
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

    /// 加载角色/舞蹈时的遮罩(模型几十 MB,后台解析要一会儿,不给反馈会被当成卡死)。
    private var loadingHUD: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(.white).scaleEffect(1.3)
                Text("正在准备舞台…").font(.footnote).foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: 步骤头部（进度）
    private var stepHeader: some View {
        let titles = ["选择角色", "选择舞蹈", "选择音乐", "开始表演"]
        return VStack(spacing: 16) {
            HStack(spacing: 20) {
                circleButton(step == .character ? "xmark" : "chevron.left") { back() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(titles[step.rawValue])
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("第 \(step.rawValue + 1) / 4 步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 进度圆环或简约进度条
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
        case .character: dismiss()          // 第一步返回=退出工作室
        case .dance:     step = .character
        case .music:     step = .dance
        case .perform:                      // 舞台页返回=直接回主页,不退回选音乐
            if recorder.isRecording { recorder.stop { _ in } }   // 录制中直接丢弃,别让写入器悬着
            music.stop(); vfx.remove()
            dismiss()
        }
    }

    // MARK: 步骤1 选角色
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

    // 选动作预览：用当前已选中的角色(没选到则用兜底模型)
    private var previewModel: String {
        character.isEmpty ? "vroid_preview.usdz" : characterModelFile(character)
    }

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
        HStack(spacing: 16) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(selected ? .white : tint)
                .frame(width: 44, height: 44)
                .background(selected ? tint : Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.system(size: 16, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.8)))

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

            VStack(spacing: 0) {
                HStack {
                    circleButton("chevron.left") { back() }
                    Spacer()
                    Picker("", selection: $arMode) { Text("屏幕").tag(false); Text("AR").tag(true) }
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

    // 场景选择条：舞台 vs 天空
    private var sceneSelectionBar: some View {
        HStack(spacing: 12) {
            sceneChip(type: .studio, title: "舞台", icon: "house.fill")
            sceneChip(type: .sky, title: "天空", icon: "cloud.sun.fill")
        }
        .padding(.bottom, 10)
    }

    private func sceneChip(type: CharacterSceneController.BackgroundType, title: String, icon: String) -> some View {
        let on = stage.controller.backgroundType == type
        return Button {
            stage.controller.backgroundType = type
            stage.objectWillChange.send() // 强制刷新 UI 以更新按钮状态
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // 底部特效选择条(参考拍摄类产品：横滑 chips + 中间大录制键)
    private var vfxBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                vfxChip(title: "关闭", icon: "nosign", on: !vfxOn) { vfxOn = false; installVFX() }
                ForEach(Array(VFXPreset.all.enumerated()), id: \.offset) { i, p in
                    vfxChip(title: p.name, icon: "sparkles", on: vfxOn && vfxPreset == i) {
                        vfxOn = true; vfxPreset = i; installVFX()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func vfxChip(title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption2)
                Text(title).font(.footnote.weight(.medium))
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(on ? 0 : 0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop { url in
                    guard let url else { return }
                    let watermark = !ProStore.shared.isPro
                    // 有音乐 或 需要水印 → 走导出;否则直接保存
                    if selectedMusic != nil || watermark {
                        processing = true
                        Task {
                            let final = await VideoAudioMixer.export(video: url, audio: selectedMusic?.url,
                                                                     watermark: watermark) ?? url
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

    // MARK: 底部主按钮
    private var bottomBar: some View {
        Button(action: next) {
            HStack(spacing: 8) {
                Text(loading ? "资源准备中…" : (step == .music ? "开始舞台表演" : "下一步"))
                if !loading {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                nextEnabled ?
                AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .leading, endPoint: .trailing)) :
                AnyShapeStyle(Color(.systemGray4))
            )
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

    // MARK: 逻辑
    private func setupInitial() {
        if let ic = initialCharacter, catalog.characters.contains(where: { $0.key == ic }) { character = ic }
        if let id = initialDance, catalog.dances.contains(where: { $0.key == id }) { dance = id }
        // 从角色库带入角色 → 直接到选舞蹈,并默认选中第一支舞
        if !character.isEmpty && initialCharacter != nil { step = .dance; ensureDefaultDance() }
    }

    /// 进入选舞蹈时,若还没选,默认选第一支。
    private func ensureDefaultDance() {
        if dance.isEmpty { dance = catalog.dances.first?.key ?? "" }
    }

    private func next() {
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

    /// 安装/刷新舞台特效(挂到角色屏幕场景,读音乐能量脉动)。
    private func installVFX() {
        vfx.remove()
        let cam = stage.controller.cameraNode?.camera
        guard vfxOn else { cam?.bloomIntensity = 0; return }
        // Bloom 辉光后处理：只让超亮的发光粒子产生柔和光晕(高阈值,避免角色白衣过曝)
        // 低端机(DeviceTier)关闭 bloom,消除全屏高斯模糊带来的卡顿。
        cam?.bloomIntensity = DeviceTier.bloomIntensity
        cam?.bloomThreshold = 0.92
        cam?.bloomBlurRadius = 14
        vfx.preset = vfxPreset
        vfx.install(in: stage.controller.scene,
                    feetY: stage.controller.feetY,
                    height: stage.controller.modelHeight,
                    level: { [weak music] in music?.currentLevel() ?? 0 })
    }

    private func select(music track: MusicTrack) {
        selectedMusic = track
        music.play(track)   // 试听
    }
}
