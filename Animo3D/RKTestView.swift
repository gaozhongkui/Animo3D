//
//  RKTestView.swift
//  Animo3D
//
//  RealityKit 播放 USDZ 骨骼动画的最小验证（非 AR，屏幕预览）。
//

import SwiftUI
import RealityKit

struct RKTestView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.init(white: 0.15, alpha: 1))

        guard let url = Bundle.main.url(forResource: "ybot_hiphop", withExtension: "usdz"),
              let entity = try? Entity.load(contentsOf: url) else {
            print("[RK] 加载失败"); return view
        }

        // 让角色站在原点，缩放到合适大小（Mixamo 常是 cm，缩到约 1.8）
        let bounds = entity.visualBounds(relativeTo: nil)
        let h = bounds.extents.y
        if h > 0 { entity.scale = SIMD3<Float>(repeating: 1.8 / h) }
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        view.scene.addAnchor(anchor)

        // 相机
        let cam = PerspectiveCamera()
        let camAnchor = AnchorEntity(world: [0, 0.9, 3.0])
        camAnchor.addChild(cam)
        cam.look(at: [0, 0.9, 0], from: [0, 0.9, 3.0], relativeTo: nil)
        view.scene.addAnchor(camAnchor)

        // 播放所有可用动画（循环）
        let anims = entity.availableAnimations
        print("[RK] availableAnimations: \(anims.count)")
        for a in anims {
            entity.playAnimation(a.repeat(duration: .infinity), transitionDuration: 0, startsPaused: false)
        }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct RKTestScreen: View {
    var body: some View { RKTestView().ignoresSafeArea() }
}
