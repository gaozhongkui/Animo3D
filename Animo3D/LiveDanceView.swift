//
//  LiveDanceView.swift
//  Animo3D
//
//  One dance previewing live, used for the selected card and the enlarged preview. Only ever one is
//  on screen at a time - a grid of these was what made the dance list stutter.
//
//  All the loading and driving lives in DancePerformer; this is just the SCNView around it.
//

import SwiftUI
import SceneKit

struct LiveDanceView: UIViewRepresentable {
    /// Character id, not a file name: the catalog decides which file that is.
    let character: String
    let dance: String
    var interactive = false   // Detail page: allow gesture rotation and zoom

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let performer = DancePerformer(owner: "LiveDanceCard")
        var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
            task = nil
            performer.stop()
        }
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
        v.scene = c.performer.controller.scene

        let ch = character, dn = dance
        c.task = Task { @MainActor in
            guard await c.performer.load(character: ch, dance: dn) else { return }
            guard !Task.isCancelled else { return }
            if let cam = c.performer.controller.cameraNode { v.pointOfView = cam }
        }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.cancel() }
    }
}
