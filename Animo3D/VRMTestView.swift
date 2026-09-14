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

    /// Empty means the bundled VRM; anything else is a catalog character, loaded as a `.scn`.
    /// Switching between them is the whole point of the page: one `.vrma` has to drive both.
    @State private var character = ""
    @ObservedObject private var assets = RemoteAssets.shared

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
                    characterPicker
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

    private var characterPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("VRM (bundled)", selected: character.isEmpty) { switchCharacter("") }
                ForEach(assets.characters.prefix(6)) { item in
                    pill(item.id.replacingOccurrences(of: "_", with: " "),
                         selected: character == item.id) { switchCharacter(item.id) }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    private var takePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.takes, id: \.self) { name in
                    pill(name.replacingOccurrences(of: "_", with: " "), selected: take == name) {
                        take = name
                        if let url = url(for: name) {
                            Task { await performer.playVRMA(url) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 24)
    }

    private func pill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor : Color.white.opacity(0.15), in: Capsule())
                .foregroundStyle(.white)
        }
    }

    private func switchCharacter(_ id: String) {
        guard id != character else { return }
        character = id
        loading = true
        Task {
            if id.isEmpty {
                await loadTestAssets()
            } else {
                // The catalog path, the same one the real stage uses - so this also proves a take
                // survives a model that was never near a VRM.
                let ok = await performer.load(character: id)
                if ok, let url = url(for: take) { await performer.playVRMA(url) }
                errorMessage = ok ? nil : "Could not load \(id)"
                loading = false
            }
        }
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
