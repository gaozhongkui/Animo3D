//
//  RKTestView.swift
//  Animo3D
//
//  Minimal check of RealityKit playing USDZ skeletal animation (not AR, an on-screen preview).
//

import SwiftUI
import RealityKit

struct RKTestView: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(.init(white: 0.15, alpha: 1))

        guard let url = Bundle.main.url(forResource: "ybot_hiphop", withExtension: "usdz"),
              let entity = try? Entity.load(contentsOf: url) else {
            print("[RK] load failed"); return view
        }

        // Put the character at the origin and scale it to a sensible size (Mixamo often exports in cm, so scale to about 1.8)
        let bounds = entity.visualBounds(relativeTo: nil)
        let h = bounds.extents.y
        if h > 0 { entity.scale = SIMD3<Float>(repeating: 1.8 / h) }
        let anchor = AnchorEntity(world: .zero)
        anchor.addChild(entity)
        view.scene.addAnchor(anchor)

        // Camera
        let cam = PerspectiveCamera()
        let camAnchor = AnchorEntity(world: [0, 0.9, 3.0])
        camAnchor.addChild(cam)
        cam.look(at: [0, 0.9, 0], from: [0, 0.9, 3.0], relativeTo: nil)
        view.scene.addAnchor(camAnchor)

        // Play every available animation (looping)
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
