//
//  MocapDanceView.swift
//  Animo3D
//
//  Prebuilt dances: loads sampled Mixamo mocap joint positions (JSON) and feeds them frame by frame to the retargeter to drive the character.
//  This sidesteps Apple's animation import problems and reuses the proven body-frame retargeting.
//

import SwiftUI
import SceneKit
import simd

/// One mocap take: 33 joint positions per frame.
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

/// Plays the mocap frame by frame with a DisplayLink, driving the retargeter.
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
    @State private var status = L("Loading…")

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
            status = L("Mocap data not found"); return
        }
        let p = MocapPlayer(frames: clip.frames, retargeter: rt)
        player = p
        p.start()
        status = String(format: L("Bones %d · Frames %d · Hip Hop"), bones.count, clip.frames.count)
    }
}
