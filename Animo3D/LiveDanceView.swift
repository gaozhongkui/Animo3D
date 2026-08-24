//
//  LiveDanceView.swift
//  Animo3D
//
//  单个"实时跳动"的舞蹈预览（SceneKit）。只给选中的卡片用，避免多个同时渲染卡顿。
//

import SwiftUI
import SceneKit

struct LiveDanceView: UIViewRepresentable {
    let model: String   // 含扩展名
    let dance: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let controller = CharacterSceneController()
        var retargeter: PoseRetargeter?
        var player: MocapPlayer?
    }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        _ = c.controller.loadModel(named: model)
        let rt = PoseRetargeter(controller: c.controller)
        c.retargeter = rt
        if let url = Bundle.main.url(forResource: dance, withExtension: "json"),
           let clip = MocapClip.load(url) {
            let p = MocapPlayer(frames: clip.frames, retargeter: rt)
            c.player = p
            p.start()
        }
        let v = SCNView()
        v.scene = c.controller.scene
        v.backgroundColor = .clear
        v.rendersContinuously = true
        v.isPlaying = true
        v.autoenablesDefaultLighting = true
        if let cam = c.controller.cameraNode { v.pointOfView = cam }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.player?.stop()
    }
}
