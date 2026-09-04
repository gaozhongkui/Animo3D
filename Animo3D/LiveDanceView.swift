//
//  LiveDanceView.swift
//  Animo3D
//
//  A single "live dancing" dance preview (SceneKit). Only used for the selected card, to avoid the stutter of rendering several at once.
//

import SwiftUI
import SceneKit

struct LiveDanceView: UIViewRepresentable {
    let model: String   // Includes the extension
    let dance: String
    var interactive = false   // Detail page: allow gesture rotation and zoom

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

        // Both the model (4-60MB) and the dance JSON (up to 1.2MB) are fetched and parsed in the
        // background. This used to load synchronously here, so tapping a dance card caused a clearly
        // visible main-thread hitch - and later, once assets moved to the CDN, it read the bundle for
        // files that were no longer in it and silently showed nothing.
        let modelFile = model, danceKey = dance
        Task.detached(priority: .userInitiated) {
            guard let modelURL = try? await RemoteAssets.shared.resolve(url: modelFile) else { return }
            // Mixamo clip regardless of rig: playback here goes through PoseRetargeter (world-space joints).
            let ref = RemoteAssets.shared.dance(danceKey)?.clip(rig: "mixamo") ?? AssetRef(url: "mocap_\(danceKey).json")
            let clipURL = try? await RemoteAssets.shared.resolve(ref)
            let scene = CharacterSceneController.loadSceneFile(at: modelURL, warmUp: true)
            let clip = clipURL.flatMap { MocapClip.load($0) }
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
