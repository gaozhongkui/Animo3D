//
//  PreviewPages.swift
//  Animo3D
//
//  Enlarged preview pages: characters can be rotated and zoomed, dances play full screen in real time, and either can be projected into AR with one tap.
//  Entered from the card's top-right "expand" button.
//

import SwiftUI
import SceneKit
import Combine

/// The "expand" button in the card's top-right corner.
struct ZoomButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// A scene that can be rotated and zoomed (3D mode). Pinch to zoom, one finger to rotate.
struct SceneOrbitView: UIViewRepresentable {
    let controller: CharacterSceneController
    var animated: Bool = false

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = controller.scene
        v.backgroundColor = .clear
        v.allowsCameraControl = true          // Gesture rotation + two-finger zoom
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = DeviceTier.antialiasing   // 4x MSAA is too heavy, so it is tiered by device
        v.rendersContinuously = animated
        v.isPlaying = animated
        if let cam = controller.cameraNode { v.pointOfView = cam }
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {
        if let cam = controller.cameraNode { v.pointOfView = cam }
    }
}

/// Holds one character controller for previewing, optionally driven by a dance; shared by 3D and AR so switching does not reload.
final class PreviewStage: ObservableObject {
    let controller = CharacterSceneController()
    @Published private(set) var ready = false
    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var loaded = false
    var animated: Bool { player != nil }

    /// Both the model and the dance data are parsed in the background and the main thread only mounts nodes - otherwise opening the enlarged preview visibly stutters.
    @MainActor
    func ensure(model: String, dance: String?) async {
        guard !loaded else { return }
        loaded = true
        if dance == nil { controller.portraitMode = true }   // Static character detail: strike an A-pose

        guard let localModelURL = try? await RemoteAssets.shared.resolve(url: model) else {
            NSLog("[PreviewStage] failed to download/locate model %@", model)
            return
        }

        let scene = await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(at: localModelURL, warmUp: true)
        }.value
        guard let scene else { return }
        controller.install(scene)
        ready = true
        guard let dance else { return }
        let rt = PoseRetargeter(controller: controller); retargeter = rt

        // Always the mixamo clip here, whatever the rig: this page drives the character through
        // PoseRetargeter, which reads world-space joint positions. A vrm clip holds bone quaternions
        // and MocapClip cannot parse it, so asking for one left every VRoid preview frozen.
        let ref = RemoteAssets.shared.dance(dance)?.clip(rig: "mixamo") ?? AssetRef(url: "mocap_\(dance).json")
        let clipURL = try? await RemoteAssets.shared.resolve(ref)
        let clip = await Task.detached(priority: .userInitiated) { () -> MocapClip? in
            guard let clipURL else { return nil }
            return MocapClip.load(clipURL)
        }.value
        if let clip {
            let p = MocapPlayer(frames: clip.frames, retargeter: rt)
            player = p; p.start()
        }
    }
    func resetRetarget() { retargeter?.resetCapture() }
    func stop() { player?.stop() }
}

/// Shared shell for the preview pages: 3D/AR switch + close + title.
private struct PreviewShell: View {
    let name: String
    let style: Int
    let model: String
    let dance: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stage = PreviewStage()
    @State private var arMode = false

    var body: some View {
        ZStack(alignment: .top) {
            CardBackdrop(style: style).ignoresSafeArea()   // Reuse the card's decorative background

            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller, onAttach: { stage.resetRetarget() })
                } else {
                    SceneOrbitView(controller: stage.controller, animated: dance != nil)
                }
            }
            .id(arMode)
            .ignoresSafeArea()

            // Top: close + 3D/AR switch
            HStack {
                CircleButton(system: "xmark") { stage.stop(); dismiss() }
                Spacer()
                Picker("", selection: $arMode) { Text("3D").tag(false); Text("AR").tag(true) }
                    .pickerStyle(.segmented).frame(width: 120)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            VStack {
                Spacer()
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(arMode ? "Move your phone to find a surface" : "Drag to rotate · pinch to zoom")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 30)
            }.frame(maxWidth: .infinity)
        }
        .overlay {
            if !stage.ready {
                ProgressView().tint(.white).scaleEffect(1.3)
            }
        }
        .task { await stage.ensure(model: model, dance: dance) }
        .onDisappear { stage.stop() }
    }
}

/// Enlarged character page (rotate and zoom + AR placement).
struct CharacterPreviewPage: View {
    let key: String
    let name: String
    var style: Int = 0
    var body: some View {
        PreviewShell(name: name, style: style, model: characterModelFile(key), dance: nil)
    }
}

/// Enlarged dance page (full-screen live dancing, rotate and zoom + AR projection).
struct DancePreviewPage: View {
    let dance: String
    let name: String
    var style: Int = 0
    var model: String = characterModelFile(BuiltInAssets.characterId)
    var body: some View {
        PreviewShell(name: name, style: style, model: model, dance: dance)
    }
}
