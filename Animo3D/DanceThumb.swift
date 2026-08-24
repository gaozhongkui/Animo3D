//
//  DanceThumb.swift
//  Animo3D
//
//  为每支舞渲染一张"角色摆出该舞蹈代表姿势"的缩略图（离屏渲染 + 缓存），
//  让选动作列表显示真实动作，而不是纯文字卡片。
//

import SwiftUI
import SceneKit

enum DanceThumb {
    private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dance_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func key(_ model: String, _ dance: String) -> String {
        "\(model)__\(dance)".replacingOccurrences(of: ".", with: "_")
    }

    static func cached(model: String, dance: String) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(key(model, dance) + ".png").path)
    }

    /// 离屏渲染角色摆出某支舞的代表帧。model 含扩展名（如 "vroid_preview.usdz"）。
    static func render(model: String, dance: String,
                       size: CGSize = CGSize(width: 360, height: 460)) -> UIImage? {
        let controller = CharacterSceneController()
        _ = controller.loadModel(named: model)
        guard controller.isLoaded, let cam = controller.cameraNode,
              let device = MTLCreateSystemDefaultDevice() else { return nil }

        // 摆出舞蹈代表帧（重定向器带平滑，重复应用同一帧使其收敛）
        if let url = Bundle.main.url(forResource: dance, withExtension: "json"),
           let clip = MocapClip.load(url), !clip.frames.isEmpty {
            let rt = PoseRetargeter(controller: controller)
            let idx = min(clip.frames.count - 1, Int(Double(clip.frames.count) * 0.45))
            for _ in 0..<12 { rt.apply(world: clip.frames[idx]) }
        }

        controller.scene.background.contents = UIColor.clear
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = controller.scene
        renderer.pointOfView = cam
        renderer.autoenablesDefaultLighting = true

        let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        if let data = img.pngData() {
            try? data.write(to: dir.appendingPathComponent(key(model, dance) + ".png"))
        }
        return img
    }
}

/// 舞蹈姿势缩略图视图。
struct DanceThumbView: View {
    let model: String   // 含扩展名
    let dance: String
    var style: Int = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CardBackdrop(style: style)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "figure.dance").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
            }
        }
        .task(id: dance) {
            if let c = DanceThumb.cached(model: model, dance: dance) { image = c; return }
            let rendered = await Task.detached(priority: .utility) {
                DanceThumb.render(model: model, dance: dance)
            }.value
            await MainActor.run { image = rendered }
        }
    }
}
