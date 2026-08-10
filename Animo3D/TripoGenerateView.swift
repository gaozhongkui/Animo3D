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

    @State private var status = "选择一张图片，生成 3D 模型"
    @State private var isRunning = false
    @State private var progress = 0
    @State private var modelScene: SCNScene?
    @State private var downloadedPath: String?

    var body: some View {
        VStack(spacing: 14) {
            // 预览区：优先显示生成的 3D 模型，否则显示选中的图片
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
                    Label("选图", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await generate() }
                } label: {
                    Label("生成 3D", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickedData == nil || apiKey.isEmpty || isRunning)
            }
            .padding(.horizontal)

            Button {
                if let url = Bundle.main.url(forResource: "tripo_sample", withExtension: "usdz"),
                   let scene = try? SCNScene(url: url) {
                    modelScene = scene
                    status = "示例：Tripo 生成的模型（已转 USDZ，可拖动旋转）"
                }
            } label: {
                Label("查看示例生成模型", systemImage: "cube").font(.footnote)
            }
            .padding(.bottom)
        }
        .navigationTitle("Tripo3D 生成角色")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if debugAutoShowSample,
               let url = Bundle.main.url(forResource: "tripo_sample", withExtension: "usdz"),
               let scene = try? SCNScene(url: url) {
                modelScene = scene
                status = "示例：Tripo 生成的模型（已转 USDZ，可拖动旋转）"
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
        status = "已选择图片，点“生成 3D”"
    }

    private func generate() async {
        guard let data = pickedData, !apiKey.isEmpty else { return }
        isRunning = true; progress = 0; modelScene = nil
        defer { isRunning = false }
        let client = TripoClient(apiKey: apiKey)
        do {
            status = "上传图片…"
            let token = try await client.uploadImage(data: data, fileExt: pickedExt)
            status = "创建生成任务…"
            let taskId = try await client.createImageToModelTask(fileToken: token, fileExt: pickedExt)
            status = "生成中（约几分钟）…"
            let modelURL = try await client.waitForCompletion(taskId: taskId) { res in
                progress = res.progress
                status = "生成中… \(res.progress)%"
            }
            status = "下载模型…"
            let local = try await client.downloadModel(from: modelURL)
            downloadedPath = local.path
            // 尝试用 SceneKit 加载（usdz/obj/dae 可；glb 不支持会失败）
            if let scene = try? SCNScene(url: local, options: nil) {
                modelScene = scene
                status = "完成 ✅ 已生成并显示模型"
            } else {
                status = "已下载模型（\(local.lastPathComponent)），但该格式 SceneKit 无法直接显示（可能是 GLB，需转换）"
            }
        } catch {
            status = "出错：\(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { TripoGenerateView() }
}
