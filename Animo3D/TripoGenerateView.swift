//
//  TripoGenerateView.swift
//  Animo3D
//
//  相册选图 → 上传 Tripo3D → 生成 3D 模型 → 下载 → 显示。
//  （“自动跳舞”需在拿到带骨骼的输出后，第二步再接重定向。）
//

import SwiftUI
import PhotosUI
import SceneKit
import UIKit

/// ⚠️ 内置默认 key（base64 编码，非加密，仅轻度混淆）。可被逆向提取，切勿发布到公开仓库/App Store。
private let embeddedTripoKeyB64 = "dHNrX2hMeDY1dVQ5RFZWeVRsSC1Rb2hfajd0VlE4dExhaE1tS0d5M3REdURYMjA="
private func embeddedTripoKey() -> String {
    guard let d = Data(base64Encoded: embeddedTripoKeyB64),
          let s = String(data: d, encoding: .utf8) else { return "" }
    return s
}

struct TripoGenerateView: View {
    // 直接用内置 key（已由 base64 内置，界面不再要求输入）
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
            // 预览区
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
                        Text("\(progress)%").font(.caption).foregroundStyle(.secondary)
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
        // 简单判断扩展名
        pickedExt = (data.starts(with: [0x89, 0x50, 0x4E, 0x47])) ? "png" : "jpg"
        status = "Image selected, click 'Generate 3D'"
    }

    private func generate() async {
        guard let data = pickedData, !apiKey.isEmpty else { return }
        isRunning = true; progress = 0; modelScene = nil
        defer { isRunning = false }
        let client = TripoClient(apiKey: apiKey)
        do {
            status = "Uploading image..."
            let token = try await client.uploadImage(data: data, fileExt: pickedExt)
            status = "Creating task..."
            let taskId = try await client.createImageToModelTask(fileToken: token, fileExt: pickedExt)
            status = "Generating (takes a few mins)..."
            let modelURL = try await client.waitForCompletion(taskId: taskId) { res in
                progress = res.progress
                status = "Generating... \(res.progress)%"
            }
            status = "Downloading model..."
            let local = try await client.downloadModel(from: modelURL)
            downloadedPath = local.path
            // 尝试用 SceneKit 加载
            if let scene = try? SCNScene(url: local, options: nil) {
                modelScene = scene
                status = "Complete ✅ Model generated"
            } else {
                status = "Model downloaded (\(local.lastPathComponent)), but SceneKit cannot display it directly (likely GLB)"
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { TripoGenerateView() }
}
