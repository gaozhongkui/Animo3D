//
//  CharacterThumb.swift
//  Animo3D
//
//  给角色渲染真实的 3D 缩略图（离屏 SCNRenderer 快照）并缓存到磁盘，
//  让角色列表显示真实形象，而不是占位图标。
//

import SwiftUI
import SceneKit

/// 按角色 key 找到实际模型文件（.scn 或 .usdz）。
func characterModelFile(_ key: String) -> String {
    for ext in ["scn", "usdz"] {
        if Bundle.main.url(forResource: key, withExtension: ext) != nil { return "\(key).\(ext)" }
    }
    return "\(key).scn"
}

enum CharacterThumb {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("char_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func cached(_ key: String) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent("\(key).png").path)
    }

    /// 离屏渲染一个角色的正面全身缩略图。较重，应在后台调用。
    static func render(_ key: String, size: CGSize = CGSize(width: 360, height: 460)) -> UIImage? {
        let controller = CharacterSceneController()
        _ = controller.loadModel(named: characterModelFile(key))
        guard controller.isLoaded, let cam = controller.cameraNode,
              let device = MTLCreateSystemDefaultDevice() else { return nil }

        controller.scene.background.contents = UIColor.clear
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = controller.scene
        renderer.pointOfView = cam
        renderer.autoenablesDefaultLighting = true

        let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        // 存盘缓存
        if let data = img.pngData() {
            try? data.write(to: dir.appendingPathComponent("\(key).png"))
        }
        return img
    }
}

/// 角色缩略图视图：优先用缓存，没有则后台渲染。
struct CharacterThumbView: View {
    let characterKey: String
    var tint: Color = .accentColor
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else {
                ProgressView().tint(tint)
            }
        }
        .task(id: characterKey) {
            if let c = CharacterThumb.cached(characterKey) { image = c; return }
            let rendered = await Task.detached(priority: .userInitiated) {
                CharacterThumb.render(characterKey)
            }.value
            await MainActor.run { image = rendered }
        }
    }
}
