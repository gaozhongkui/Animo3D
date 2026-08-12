//
//  ARCharacterView.swift
//  Animo3D
//
//  用 ARKit 世界追踪 + 水平面检测，把角色放到真实地面上：
//  引导蒙层找地面 → 点击地面放置 → 锚定，角色稳稳站在地板上，仍由动作驱动。
//  世界追踪 A9+ 即支持（iPhone X 可用）。
//

import SwiftUI
import ARKit
import SceneKit

struct ARCharacterView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onAttach: onAttach)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true
        context.coordinator.setup(arView)

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            arView.session.run(config)

            // 找地面的引导蒙层
            let coaching = ARCoachingOverlayView()
            coaching.session = arView.session
            coaching.goal = .horizontalPlane
            coaching.activatesAutomatically = true
            coaching.translatesAutoresizingMaskIntoConstraints = false
            arView.addSubview(coaching)
            NSLayoutConstraint.activate([
                coaching.topAnchor.constraint(equalTo: arView.topAnchor),
                coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
                coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            ])

            // 点击地面放置
            let tap = UITapGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            arView.addGestureRecognizer(tap)
        }
        holder?.scnView = arView
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject {
        private let controller: CharacterSceneController
        private let onAttach: (() -> Void)?
        private weak var arView: ARSCNView?
        private var container: SCNNode?      // 承载角色：缩放 + 摆到地面
        private(set) var placed = false

        init(controller: CharacterSceneController, onAttach: (() -> Void)?) {
            self.controller = controller
            self.onAttach = onAttach
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            guard let root = controller.characterRoot else { return }
            root.removeFromParentNode()
            let c = SCNNode()
            let h = controller.modelHeight
            if h > 0 { let s = 1.3 / h; c.scale = SCNVector3(s, s, s) }  // 约 1.3m 高
            c.addChildNode(root)
            c.isHidden = true                 // 放置前先隐藏
            container = c
            arView.scene.rootNode.addChildNode(c)
            onAttach?()
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView, let container else { return }
            let pt = g.location(in: arView)
            // 优先命中已检测到的平面，否则用估计平面
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
            guard let q = query, let hit = arView.session.raycast(q).first else { return }
            let t = hit.worldTransform
            container.simdPosition = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            container.isHidden = false
            placed = true
        }
    }
}
