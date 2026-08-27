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
    var interactive = false   // 详情页：允许手势旋转/缩放

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let controller = CharacterSceneController()
        var retargeter: PoseRetargeter?
        var player: MocapPlayer?
        var cancelled = false
    }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        let v = SCNView()
        v.backgroundColor = .clear
        v.rendersContinuously = true
        v.isPlaying = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = DeviceTier.antialiasing
        v.allowsCameraControl = interactive

        // 模型(10~60MB)与舞蹈 JSON(最大 1.2MB)都放后台解析。
        // 以前在这里同步加载,点一下舞蹈卡片就是一次明显的主线程卡顿。
        let modelFile = model, danceKey = dance
        Task.detached(priority: .userInitiated) {
            let scene = CharacterSceneController.loadSceneFile(named: modelFile, warmUp: true)
            let clip = Bundle.main.url(forResource: danceKey, withExtension: "json").flatMap { MocapClip.load($0) }
            await MainActor.run {
                guard !c.cancelled, let scene else { return }
                c.controller.install(scene)
                v.scene = c.controller.scene
                if let cam = c.controller.cameraNode { v.pointOfView = cam }
                let rt = PoseRetargeter(controller: c.controller)
                c.retargeter = rt
                if let clip {
                    let p = MocapPlayer(frames: clip.frames, retargeter: rt)
                    c.player = p
                    p.start()
                }
            }
        }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.cancelled = true
        coordinator.player?.stop()
    }
}
