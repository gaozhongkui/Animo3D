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

/// Shared shell for the preview pages: 3D/AR switch + close + title.
private struct PreviewShell: View {
    let name: String
    let style: Int
    let character: String
    let dance: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stage = DancePerformer(owner: "PreviewShell")
    @State private var arMode = false

    var body: some View {
        ZStack(alignment: .top) {
            CardBackdrop(style: style).ignoresSafeArea()   // Reuse the card's decorative background

            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller, onAttach: { stage.resetRetarget() })
                } else {
                    SceneOrbitView(controller: stage.controller, animated: stage.isAnimating)
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
            if !stage.isReady {
                ProgressView().tint(.white).scaleEffect(1.3)
            }
        }
        .task { await stage.load(character: character, dance: dance) }
        .onDisappear { stage.stop() }
    }
}

/// Enlarged character page (rotate and zoom + AR placement).
struct CharacterPreviewPage: View {
    let key: String
    let name: String
    var style: Int = 0
    var body: some View {
        PreviewShell(name: name, style: style, character: key, dance: nil)
    }
}

/// Enlarged dance page (full-screen live dancing, rotate and zoom + AR projection).
struct DancePreviewPage: View {
    let dance: String
    let name: String
    var style: Int = 0
    /// Who performs it. Defaults to the built-in character, which needs no download.
    var character: String = ""
    var body: some View {
        PreviewShell(name: name, style: style,
                     character: character.isEmpty ? BuiltInAssets.characterId : character,
                     dance: dance)
    }
}
