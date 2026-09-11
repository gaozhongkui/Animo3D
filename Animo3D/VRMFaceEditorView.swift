//
//  VRMFaceEditorView.swift
//  Animo3D
//
//  A dynamic test interface for adjusting VRM Expressions.
//

import SwiftUI
import SceneKit

struct VRMFaceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var performer = DancePerformer(owner: "FaceEditor", groundEnabled: false)
    @State private var loading = true
    @State private var availableExpressions: [String] = []
    @State private var weights: [String: Float] = [:]

    var body: some View {
        ZStack {
            Color(white: 0.1).ignoresSafeArea()

            if performer.isReady {
                CharacterSceneView(controller: performer.controller)
                    .ignoresSafeArea()
                    .onAppear {
                        performer.controller.setupFrontCamera()
                        let h = performer.controller.modelHeight
                        performer.controller.cameraNode?.simdPosition.y += h * 0.2
                    }
            }

            VStack {
                header
                Spacer()
                if !loading {
                    if availableExpressions.isEmpty {
                        Text("No VRM Expressions found in this model")
                            .foregroundStyle(.secondary)
                            .padding(40)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    } else {
                        controlsPanel
                    }
                }
            }

            if loading {
                ProgressView("Analyzing Model...").tint(.white).foregroundStyle(.white)
            }
        }
        .task {
            await loadModel()
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Text("VRM Face Editor").font(.headline).foregroundStyle(.white)
            Spacer()
            Button("Reset") { reset() }.font(.subheadline).foregroundStyle(.cyan)
        }
        .padding()
        .background(.black.opacity(0.3))
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(spacing: 20) {
                ForEach(availableExpressions, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name).font(.caption).foregroundStyle(.white)
                            Spacer()
                            Text(String(format: "%.2f", weights[name] ?? 0)).font(.caption.monospaced()).foregroundStyle(.cyan)
                        }
                        Slider(value: Binding(
                            get: { weights[name] ?? 0 },
                            set: { newValue in
                                weights[name] = newValue
                                performer.setBlendShape(value: newValue, for: name)
                            }
                        ), in: 0...1)
                        .tint(.cyan)
                    }
                }
            }
            .padding()
        }
        .frame(height: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func loadModel() async {
        guard let modelURL = Bundle.main.url(forResource: "TestCharacter", withExtension: "glb") else { return }
        await performer.loadLocal(modelURL: modelURL, isVRM: true)

        // 动态发现模型支持的表情列表
        availableExpressions = performer.getAvailableVRMExpressions()
        weights = Dictionary(uniqueKeysWithValues: availableExpressions.map { ($0, 0.0) })

        loading = false
    }

    private func reset() {
        for name in availableExpressions {
            weights[name] = 0
            performer.setBlendShape(value: 0, for: name)
        }
    }
}
