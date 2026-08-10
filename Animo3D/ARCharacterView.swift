//
//  ARCharacterView.swift
//  Animo3D
//
//  用 ARKit 世界追踪把角色摆到现实空间里（站在你面前的地上），
//  仍由视频动作驱动。世界追踪 A9+ 即支持（iPhone X 可用）。
//

import SwiftUI
import ARKit
import SceneKit

struct ARCharacterView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            arView.session.run(config)
        }

        // 把角色挂到 AR 场景：容器负责缩放到真实身高 + 摆到前方地面
        if let root = controller.characterRoot {
            root.removeFromParentNode()
            let container = SCNNode()
            let h = controller.modelHeight
            if h > 0 {
                let s = 1.6 / h                    // 缩放到约 1.6m 高
                container.scale = SCNVector3(s, s, s)
            }
            container.position = SCNVector3(0, -0.9, -2.2)  // 前方 2.2m、略低（地面）
            container.addChildNode(root)
            arView.scene.rootNode.addChildNode(container)
        }
        onAttach?()   // 让重定向重新采样（角色已换到 AR 场景）
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: ()) {
        uiView.session.pause()
    }
}
