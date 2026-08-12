//
//  MocapDanceView.swift
//  Animo3D
//
//  预制舞蹈：加载采样好的 Mixamo 动捕关节位置(JSON)，逐帧喂给重定向器驱动角色。
//  绕开苹果的动画导入问题，复用已验证的 body-frame 重定向。
//

import SwiftUI
import SceneKit
import simd

/// 一段动捕：每帧 33 个关节位置。
struct MocapClip {
    let fps: Double
    let frames: [[simd_float3]]

    static func load(_ url: URL) -> MocapClip? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawFrames = obj["frames"] as? [[[Double]]] else { return nil }
        let fps = (obj["fps"] as? Double) ?? 30
        let frames: [[simd_float3]] = rawFrames.map { frame in
            frame.map { p in simd_float3(Float(p[0]), Float(p[1]), Float(p[2])) }
        }
        return MocapClip(fps: fps, frames: frames)
    }
}

/// 用 DisplayLink 逐帧播放动捕，驱动重定向器。
final class MocapPlayer {
    private let frames: [[simd_float3]]
    private let retargeter: PoseRetargeter
    private var link: CADisplayLink?
    private var idx = 0

    init(frames: [[simd_float3]], retargeter: PoseRetargeter) {
        self.frames = frames
        self.retargeter = retargeter
    }

    func start() {
        link?.invalidate()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick() {
        guard !frames.isEmpty else { return }
        retargeter.apply(world: frames[idx])
        idx = (idx + 1) % frames.count
    }
}

struct MocapDanceView: View {
    private let character = CharacterSceneController()
    @State private var retargeter: PoseRetargeter?
    @State private var player: MocapPlayer?
    @State private var status = "加载中…"

    var body: some View {
        VStack {
            CharacterSceneView(controller: character)
            Text(status).font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear(perform: setup)
    }

    private func setup() {
        guard retargeter == nil else { return }
        let bones = character.loadModel(named: "ybot.scn")
        let rt = PoseRetargeter(controller: character)
        retargeter = rt
        guard let url = Bundle.main.url(forResource: "hiphop", withExtension: "json"),
              let clip = MocapClip.load(url) else {
            status = "找不到动捕数据"; return
        }
        let p = MocapPlayer(frames: clip.frames, retargeter: rt)
        player = p
        p.start()
        status = "骨骼 \(bones.count) · 帧 \(clip.frames.count) · Hip Hop"
    }
}
