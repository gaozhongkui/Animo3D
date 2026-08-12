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
    private let catalog = Catalog.load()
    @StateObject private var stage = DanceStage()
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @State private var character = ""
    @State private var dance = ""
    @State private var arMode = false
    @State private var shareURL: URL?
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .top) {
                Group {
                    if arMode {
                        ARCharacterView(controller: stage.controller,
                                        onAttach: { stage.resetRetarget() },
                                        holder: holder)
                    } else {
                        CharacterSceneView(controller: stage.controller,
                                           onAttach: { stage.resetRetarget() },
                                           holder: holder)
                    }
                }
                .id(arMode)   // 只在屏幕/AR 切换时重建；换角色原地换模型        // 换角色 / 切 AR 时重建视图

                Picker("", selection: $arMode) {
                    Text("屏幕").tag(false)
                    Text("AR").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .padding(8)
            }
            .overlay(alignment: .bottom) { recordButton.padding(.bottom, 14) }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10)

            picker(title: "角色", items: catalog.characters, selection: $character) { new in
                stage.load(character: new, dance: dance)
            }
            picker(title: "舞蹈", items: catalog.dances, selection: $dance) { new in
                stage.playDance(new)
            }
            .padding(.bottom, 6)
        }
        .navigationTitle("舞蹈工作室")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .onAppear {
            character = catalog.characters.first?.key ?? ""
            dance = catalog.dances.first?.key ?? ""
            if !character.isEmpty { stage.load(character: character, dance: dance) }
            if debugAutoRecord {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if let v = holder.scnView { recorder.start(view: v) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    recorder.stop { url in
                        if let url { _ = WorksStore.shared.add(from: url); print("[Rec] saved works") }
                        else { print("[Rec] failed") }
                    }
                }
            }
        }
    }

    private let debugAutoRecord = false

    private var recordButton: some View {
        Button {
            if recorder.isRecording {
                recorder.stop { url in
                    if let url, let saved = WorksStore.shared.add(from: url) {
                        shareURL = saved
                        showShare = true
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
                            .background(sel ? Color.accentColor : Color(.secondarySystemBackground),
                                        in: Capsule())
                            .foregroundStyle(sel ? .white : .primary)
                            .onTapGesture {
                                selection.wrappedValue = item.key
                                onSelect(item.key)
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }
}
