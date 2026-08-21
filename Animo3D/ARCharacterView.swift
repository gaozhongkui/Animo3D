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
    /// true=扫地面后落到地板；false=不做地面检测，直接摆到镜头正前方（快速验证用）。
    var detectGround: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onAttach: onAttach, detectGround: detectGround)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = true
        arView.delegate = context.coordinator   // 检测到平面时自动放置
        context.coordinator.setup(arView)

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = detectGround ? [.horizontal] : []
            arView.session.run(config)

            if detectGround {
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
        }
        holder?.scnView = arView
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        private let controller: CharacterSceneController
        private let onAttach: (() -> Void)?
        private let detectGround: Bool
        private weak var arView: ARSCNView?
        private var container: SCNNode?      // 承载角色：缩放 + 摆到地面
        private(set) var placed = false

        init(controller: CharacterSceneController, onAttach: (() -> Void)?, detectGround: Bool) {
            self.controller = controller
            self.onAttach = onAttach
            self.detectGround = detectGround
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView

            // 先尝试触发加载逻辑
            onAttach?()

            guard let root = controller.characterRoot else {
                print("[AR] 等待模型加载中...")
                return
            }

            root.removeFromParentNode()
            let c = SCNNode()
            let h = controller.modelHeight
            // 如果高度获取失败（比如模型未居中），给个默认缩放防止看不见
            let s: Float = (h > 0.01) ? (1.3 / h) : 1.0
            c.scale = SCNVector3(s, s, s)

            c.addChildNode(root)
            // 让模型底部落在容器原点：放置到平面时是“脚踩地”，而非中心埋进地板。
            let minY = lowestY(of: root, in: c)
            if minY.isFinite { root.simdPosition.y -= minY }
            container = c
            arView.scene.rootNode.addChildNode(c)

            if detectGround {
                c.isHidden = true          // 等扫到地面/点击后再显示
                placed = false
            } else {
                // 不做地面检测：直接摆到镜头正前方 1.6m、略低于视线，立即可见。
                c.simdPosition = simd_float3(0, -0.8, -1.6)
                c.isHidden = false
                placed = true
            }
            print("[AR] 模型已准备, 高度=\(h) 缩放=\(s) 落地偏移=\(minY) 地面检测=\(detectGround)")
        }

        /// 在容器 c 的局部坐标系里，求整棵子树几何体的最低 Y（用于落地偏移）。
        private func lowestY(of root: SCNNode, in c: SCNNode) -> Float {
            var minY = Float.greatestFiniteMagnitude
            root.enumerateHierarchy { node, _ in
                guard node.geometry != nil else { return }
                let (a, b) = node.boundingBox
                for x in [Float(a.x), Float(b.x)] {
                    for y in [Float(a.y), Float(b.y)] {
                        for z in [Float(a.z), Float(b.z)] {
                            let p = node.simdConvertPosition(simd_float3(x, y, z), to: c)
                            minY = min(minY, p.y)
                        }
                    }
                }
            }
            return minY
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView, let container else { return }
            let pt = g.location(in: arView)
            // 优先命中已检测到的平面，否则用估计平面
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
            guard let q = query, let hit = arView.session.raycast(q).first else { return }
            place(at: hit.worldTransform)   // 点击可重新摆放/挪位
        }

        /// 检测到水平面时自动放置一次，省得用户不知道要点屏幕。之后仍可点击挪位。
        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard !placed, anchor is ARPlaneAnchor else { return }
            let t = anchor.transform
            DispatchQueue.main.async { [weak self] in self?.place(at: t) }
        }

        private func place(at transform: simd_float4x4) {
            guard let container else { return }
            container.simdPosition = SIMD3(transform.columns.3.x,
                                           transform.columns.3.y,
                                           transform.columns.3.z)
            container.isHidden = false
            placed = true
        }
    }
}
