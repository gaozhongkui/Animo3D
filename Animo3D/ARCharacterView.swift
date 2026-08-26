//
//  ARCharacterView.swift
//  Animo3D
//
//  ARKit 世界追踪 + 水平面检测,把角色稳稳放到真实地面:
//  ① 屏幕中心准星实时贴合检测到的地面(看得见能放哪)
//  ② 平面用半透明网格可视化
//  ③ 点击=创建 ARAnchor 锚定,角色挂在 anchor 节点下 → 追踪修正时钉着地面不飘/不陷
//  角色脚底对齐地面,仍由动作驱动。世界追踪 A9+(iPhone X 可用)。
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
        arView.delegate = context.coordinator
        context.coordinator.setup(arView)

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = detectGround ? [.horizontal] : []
            config.environmentTexturing = .automatic
            arView.session.run(config)

            if detectGround {
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
        private var container: SCNNode?      // 承载角色：缩放 + 脚底对齐
        private var reticle: SCNNode?        // 地面准星
        private var planeNodes: [UUID: SCNNode] = [:]
        private(set) var placed = false

        init(controller: CharacterSceneController, onAttach: (() -> Void)?, detectGround: Bool) {
            self.controller = controller
            self.onAttach = onAttach
            self.detectGround = detectGround
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            onAttach?()

            guard let root = controller.characterRoot else {
                print("[AR] 等待模型加载中...")
                return
            }

            root.removeFromParentNode()
            let c = SCNNode()
            let h = controller.modelHeight
            let s: Float = (h > 0.01) ? (1.3 / h) : 1.0   // 角色约 1.3m
            c.scale = SCNVector3(s, s, s)
            c.addChildNode(root)
            // 脚底落到容器原点(放置时脚踩地,不埋进地板)
            let minY = lowestY(of: root, in: c)
            if minY.isFinite { root.simdPosition.y -= minY }
            container = c

            if detectGround {
                c.isHidden = true          // 放置后才显示;先不挂进场景,放置时挂到 anchor 节点
                placed = false
                addReticle(arView)
            } else {
                c.simdPosition = simd_float3(0, -0.8, -1.6)
                c.isHidden = false
                placed = true
                arView.scene.rootNode.addChildNode(c)
            }
            print("[AR] 模型已准备 高度=\(h) 缩放=\(s) 落地偏移=\(minY) 地面检测=\(detectGround)")
        }

        // MARK: 准星
        private func addReticle(_ arView: ARSCNView) {
            let ring = SCNTorus(ringRadius: 0.14, pipeRadius: 0.006)
            ring.firstMaterial?.diffuse.contents = UIColor.systemGreen
            ring.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: ring)
            let dot = SCNNode(geometry: SCNSphere(radius: 0.012))
            dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
            dot.geometry?.firstMaterial?.lightingModel = .constant
            node.addChildNode(dot)
            node.isHidden = true
            arView.scene.rootNode.addChildNode(node)
            reticle = node
        }

        /// 每帧把准星贴到屏幕中心命中的地面。
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard detectGround, !placed, let arView, let reticle else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let q = arView.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .horizontal),
                  let hit = arView.session.raycast(q).first else {
                reticle.isHidden = true
                return
            }
            reticle.simdWorldTransform = hit.worldTransform
            reticle.isHidden = false
        }

        private func lowestY(of root: SCNNode, in c: SCNNode) -> Float {
            var minY = Float.greatestFiniteMagnitude
            root.enumerateHierarchy { node, _ in
                guard node.geometry != nil else { return }
                let (a, b) = node.boundingBox
                for x in [Float(a.x), Float(b.x)] { for y in [Float(a.y), Float(b.y)] { for z in [Float(a.z), Float(b.z)] {
                    let p = node.simdConvertPosition(simd_float3(x, y, z), to: c)
                    minY = min(minY, p.y)
                }}}
            }
            return minY
        }

        // MARK: 点击放置 → 创建 ARAnchor 锚定
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            let pt = g.location(in: arView)
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
            guard let q = query, let hit = arView.session.raycast(q).first else { return }
            // 已放置=挪位:直接移动;未放置=加锚点
            if placed, let container {
                container.simdWorldTransform = hit.worldTransform
            } else {
                let anchor = ARAnchor(name: "placement", transform: hit.worldTransform)
                arView.session.add(anchor: anchor)
            }
        }

        // MARK: 平面可视化 + 锚定放置
        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            if let plane = anchor as? ARPlaneAnchor {
                let g = SCNPlane(width: CGFloat(plane.planeExtent.width), height: CGFloat(plane.planeExtent.height))
                g.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
                g.firstMaterial?.isDoubleSided = true
                let p = SCNNode(geometry: g)
                p.eulerAngles.x = -Float.pi / 2
                p.simdPosition = simd_float3(plane.center.x, 0, plane.center.z)
                node.addChildNode(p)
                planeNodes[plane.identifier] = p
                return
            }
            // 我们的放置锚点:把角色挂到锚点节点(跟随锚点 = 钉地面不飘)
            if anchor.name == "placement", let container, !placed {
                container.removeFromParentNode()
                node.addChildNode(container)
                container.simdPosition = .zero
                container.isHidden = false
                placed = true
                reticle?.isHidden = true
                // 放置后隐藏平面网格,避免遮挡
                planeNodes.values.forEach { $0.isHidden = true }
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor,
                  let p = planeNodes[plane.identifier], let g = p.geometry as? SCNPlane else { return }
            g.width = CGFloat(plane.planeExtent.width)
            g.height = CGFloat(plane.planeExtent.height)
            p.simdPosition = simd_float3(plane.center.x, 0, plane.center.z)
        }
    }
}
