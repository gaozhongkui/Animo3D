//
//  VRMTestView.swift
//  Animo3D
//
//  A standalone test page to verify VRM loading (via VRMKit) and `.vrma` dance playback.
//

import SwiftUI
import SceneKit

struct VRMTestView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var performer = DancePerformer(owner: "VRMTest", groundEnabled: true)
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var take = Self.takes[0]

    /// Bundled `.vrma` takes. The first is the one the page opens on.
    /// `MaftyDance` was authored as a `.vrma`; the rest came off Mixamo through `fbx_to_vrma.py`,
    /// so the pair answers whether a converted take holds up next to a native one.
    private static let takes = ["MaftyDance", "Gangnam_Style", "Hip_Hop_Dancing", "Samba_Dancing"]

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

                if !loading && errorMessage == nil {
                    takePicker
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

    private var takePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.takes, id: \.self) { name in
                    Button {
                        take = name
                        Task { await performer.playVRMA(url(for: name) ?? URL(fileURLWithPath: "/")) }
                    } label: {
                        Text(name.replacingOccurrences(of: "_", with: " "))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(take == name ? Color.accentColor : Color.white.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 24)
    }

    private func url(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "vrma")
    }

    private func loadTestAssets() async {
        // Model: TestCharacter.glb (VRM 0.x, exported from VRoid Studio)

        guard let modelURL = Bundle.main.url(forResource: "TestCharacter", withExtension: "glb"),
              let danceURL = url(for: take) else {
            errorMessage = "Missing local test resources (TestCharacter.glb or \(take).vrma)"
            loading = false
            return
        }

        let ok = await performer.loadLocal(modelURL: modelURL, vrmaURL: danceURL, isVRM: true)

        if !ok {
            errorMessage = "Failed to load assets. Check logs for VRMKit errors."
        }

        loading = false
    }
}

#Preview {
    VRMTestView()
}
