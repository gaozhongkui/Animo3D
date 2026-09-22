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
    /// Width / height of the box this fills, so the camera can be framed on the whole take. The
    /// default is the card grid's shape.
    var aspect: Float = 3.0 / 4.0
    /// The accent of the backdrop behind this view; the dancer is rimmed in it so the two read as
    /// one light. Nil leaves the rig's white rim alone.
    var accent: Color? = nil

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
        v.preferredFramesPerSecond = 60
        if UIDevice.current.userInterfaceIdiom == .pad {
            v.contentScaleFactor = min(v.contentScaleFactor, 1.5) // 卡片预览进一步降低采样以保流畅
        }
        // Off: it adds a white omni on the camera, over the rig the controller already installed,
        // and a flat frontal fill is what made the dancer read as a sticker rather than a figure
        // standing in the light the card is painted with.
        v.autoenablesDefaultLighting = false
        v.antialiasingMode = DeviceTier.antialiasing
        v.allowsCameraControl = interactive
        v.scene = c.performer.controller.scene

        c.performer.controller.setRimTint(accent.map { UIColor($0) })

        let ch = character, dn = dance, ar = aspect
        c.task = Task { @MainActor in
            guard await c.performer.load(character: ch, dance: dn) else { return }
            guard !Task.isCancelled else { return }
            // install() rebuilds the rig, so the tint has to be re-applied once the model is in.
            c.performer.controller.setRimTint(accent.map { UIColor($0) })
            // Before the first frame is shown: the install-time camera frames a standing character,
            // and a take that jumps or travels would carry the dancer out of a card this small. The
            // camera rides the dance from here rather than standing back far enough to contain it.
            c.performer.followCameraOnTake(aspect: ar)
            if let cam = c.performer.controller.cameraNode { v.pointOfView = cam }
        }
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.cancel() }
    }
}
