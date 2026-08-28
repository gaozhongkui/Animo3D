//
//  TripoGenerateView.swift
//  Animo3D
//
//  Select image from album -> Upload to Tripo3D -> Generate 3D model -> Download -> Display.
//  ("Auto-dancing" requires retargeting in a second step after getting the rigged output.)
//

import SwiftUI
import PhotosUI
import SceneKit
import UIKit

/// ⚠️ Built-in default key (base64 encoded, not encrypted, only lightly obfuscated). Can be reverse-engineered, do not publish to public repositories/App Store.
private let embeddedTripoKeyB64 = "dHNrX2hMeDY1dVQ5RFZWeVRsSC1Rb2hfajd0VlE4dExhaE1tS0d5M3REdURYMjA="
private func embeddedTripoKey() -> String {
    guard let d = Data(base64Encoded: embeddedTripoKeyB64),
          let s = String(data: d, encoding: .utf8) else { return "" }
    return s
}

struct TripoGenerateView: View {
    // Directly use the built-in key (already embedded as base64, UI no longer prompts for input)
    private var apiKey: String { embeddedTripoKey() }
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var pickedData: Data?
    @State private var pickedExt = "jpg"

    @State private var status = "Select an image to generate 3D model"
    @State private var isRunning = false
    @State private var progress = 0
    @State private var modelScene: SCNScene?
    @State private var downloadedPath: String?

    var body: some View {
        VStack(spacing: 14) {
            // Preview area
            ZStack {
                Color(.secondarySystemBackground)
                if let scene = modelScene {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                } else if let img = pickedImage {
                    Image(uiImage: img).resizable().scaledToFit().padding()
                } else {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 60)).foregroundStyle(.tertiary)
                }
                if isRunning {
                    VStack {
                        ProgressView()
                        Text(String(format: L("%d%%"), progress)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)

            Text(status).font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal)

            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Select", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await generate() }
                } label: {
                    Label("Generate 3D", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickedData == nil || apiKey.isEmpty || isRunning)
            }
            .padding(.horizontal)

            Button {
                if let url = Bundle.main.url(forResource: "tripo_sample", withExtension: "usdz"),
                   let scene = try? SCNScene(url: url) {
                    modelScene = scene
                    status = "Example: Tripo generated model (drag to rotate)"
                }
            } label: {
                Label("View Sample Model", systemImage: "cube").font(.footnote)
            }
            .padding(.bottom)
        }
        .navigationTitle("AI Model Generator")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if debugAutoShowSample,
               let url = Bundle.main.url(forResource: "tripo_sample", withExtension: "usdz"),
               let scene = try? SCNScene(url: url) {
                modelScene = scene
                status = "Example: Tripo generated model (drag to rotate)"
            }
        }
        .onChange(of: pickerItem) { item in
            guard let item else { return }
            Task { await loadImage(item) }
        }
    }

    private let debugAutoShowSample = false

    private func loadImage(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        pickedData = data
        pickedImage = UIImage(data: data)
        modelScene = nil
        // Simple extension check
        pickedExt = (data.starts(with: [0x89, 0x50, 0x4E, 0x47])) ? "png" : "jpg"
        status = L("Image selected, click 'Generate 3D'")
    }

    private func generate() async {
        guard let data = pickedData, !apiKey.isEmpty else { return }
        isRunning = true; progress = 0; modelScene = nil
        defer { isRunning = false }
        let client = TripoClient(apiKey: apiKey)
        do {
            status = L("Uploading image...")
            let token = try await client.uploadImage(data: data, fileExt: pickedExt)
            status = L("Creating task...")
            let taskId = try await client.createImageToModelTask(fileToken: token, fileExt: pickedExt)
            status = L("Generating (takes a few mins)...")
            let modelURL = try await client.waitForCompletion(taskId: taskId) { res in
                progress = res.progress
                status = String(format: L("Generating... %d%%"), res.progress)
            }
            status = L("Downloading model...")
            let local = try await client.downloadModel(from: modelURL)
            downloadedPath = local.path
            // Attempt to load with SceneKit
            if let scene = try? SCNScene(url: local, options: nil) {
                modelScene = scene
                status = L("Complete ✅ Model generated")
            } else {
                status = String(format: L("Model downloaded (%@), but SceneKit cannot display it directly (likely GLB)"), local.lastPathComponent)
            }
        } catch {
            status = String(format: L("Error: %@"), error.localizedDescription)
        }
    }
}

#Preview {
    NavigationStack { TripoGenerateView() }
}
