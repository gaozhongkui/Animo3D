//
//  VRMTestView.swift
//  Animo3D
//
//  A standalone test page to verify VRM loading (via VRMKit) and Mixamo dance playback.
//

import SwiftUI
import SceneKit

struct VRMTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var performer = DancePerformer(owner: "VRMTest", groundEnabled: true)
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if performer.isReady {
                CharacterSceneView(controller: performer.controller)
                    .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                if let error = errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                if loading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading Test Assets...")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .padding(32)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
            }
        }
        .task {
            await loadTestAssets()
        }
        .onDisappear {
            performer.stop()
        }
    }

    private func loadTestAssets() async {
        // Model: TestCharacter.glb (VRM format)
        // Dance: Flair.json (Converted from Flair.dae)

        guard let modelURL = Bundle.main.url(forResource: "TestCharacter", withExtension: "glb"),
              let danceURL = Bundle.main.url(forResource: "Flair", withExtension: "json") else {
            errorMessage = "Missing local test resources (TestCharacter.glb or Flair.json)"
            loading = false
            return
        }

        let ok = await performer.loadLocal(modelURL: modelURL, danceURL: danceURL, isVRM: true)

        if !ok {
            errorMessage = "Failed to load assets. Check logs for VRMKit errors."
        }

        loading = false
    }
}

#Preview {
    VRMTestView()
}
