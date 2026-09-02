//
//  ARCharacterView.swift
//  Animo3D
//
//  ARKit World Tracking + Horizontal Plane Detection: Securely place the character on the real floor:
//  ① The screen center reticle real-time fits the detected ground (visible indication of placement location)
//  ② Visualize planes with translucent grids
//  ③ Tap = Create ARAnchor, the character is attached to the anchor node -> keeps the character fixed to the ground without drifting or sinking during tracking corrections
//  The character's feet align with the ground, still driven by motion data. World tracking requires A9+ (iPhone X and later).
//

import SwiftUI
import ARKit
import SceneKit

struct ARCharacterView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil
    /// Called with the character's container once it is standing in the world, so the caller can
    /// hang effects off it and take its placement guidance down.
    var onPlaced: ((SCNNode) -> Void)? = nil
    var holder: SceneHolder? = nil
    /// true = land on the floor after scanning the ground; false = no ground detection, place directly in front of the camera (for quick validation).
    var detectGround: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onAttach: onAttach, onPlaced: onPlaced, detectGround: detectGround)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        // Light estimation still drives the scene's lighting environment, but the default light
        // is off: it stacked on top of the environment texture and blew the character out.
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = false
        arView.delegate = context.coordinator
        context.coordinator.setup(arView)

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = detectGround ? [.horizontal] : []
            config.environmentTexturing = .automatic

            // 开启人像遮挡 (People Occlusion)
            // 需要 A12 芯片及以上机型，iOS 13+ 支持基本遮挡，但 iOS 16+ 的深度信息更精准
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
                print("[AR] People Occlusion enabled")
            } else {
                print("[AR] People Occlusion not supported on this device")
            }

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

                // --- 新增手势支持 ---
                // 缩放
                let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
                arView.addGestureRecognizer(pinch)

                // 旋转
                let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
                arView.addGestureRecognizer(rotate)

                // 拖拽平移
                let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
                pan.maximumNumberOfTouches = 1 // 确保不与两指手势冲突
                arView.addGestureRecognizer(pan)
            }
        }
        holder?.scnView = arView
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
        coordinator.restoreCharacter()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        private let controller: CharacterSceneController
        private let onAttach: (() -> Void)?
        private let onPlaced: ((SCNNode) -> Void)?
        private let detectGround: Bool
        private weak var arView: ARSCNView?
        private var container: SCNNode?      // Carries the character: scaling + sole alignment
        private var reticle: SCNNode?        // Ground reticle
        private var planeNodes: [UUID: SCNNode] = [:]
        private(set) var placed = false
        /// How far the character was pushed down so its feet sit on the container origin. Kept so
        /// leaving AR can put it back - the screen stage shares the same node.
        private var groundOffset: Float = 0

        init(controller: CharacterSceneController, onAttach: (() -> Void)?,
             onPlaced: ((SCNNode) -> Void)?, detectGround: Bool) {
            self.controller = controller
            self.onAttach = onAttach
            self.onPlaced = onPlaced
            self.detectGround = detectGround
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            addLights(to: arView)
            onAttach?()

            guard let root = controller.characterRoot else {
                print("[AR] waiting for the model to load...")
                return
            }

            root.removeFromParentNode()
            let c = SCNNode()
            let h = controller.modelHeight
            let s: Float = (h > 0.01) ? (1.3 / h) : 1.0   // The character is about 1.3m
            c.scale = SCNVector3(s, s, s)
            c.addChildNode(root)
            // The feet land at the container origin (so the feet are on the ground when placed, not buried in the floor)
            let minY = lowestY(of: root, in: c)
            if minY.isFinite {
                root.simdPosition.y -= minY
                groundOffset = minY
            }
            container = c
            addShadowCatcher(to: c, height: h)

            if detectGround {
                c.isHidden = true          // Display only after placement; don't attach to scene yet, attach to anchor node during placement
                placed = false
                addReticle(arView)
            } else {
                c.simdPosition = simd_float3(0, -0.8, -1.6)
                c.isHidden = false
                placed = true
                arView.scene.rootNode.addChildNode(c)
                notifyPlaced(c)
            }
            print("[AR] model ready height=\(h) scale=\(s) groundOffset=\(minY) detectGround=\(detectGround)")
        }

        /// A modest, predictable rig. Environment texturing needs an A12 and a settled probe, so
        /// without these the character can come out black on older devices or right after launch.
        private func addLights(to arView: ARSCNView) {
            guard arView.scene.rootNode.childNode(withName: "ar_lights", recursively: false) == nil else { return }
            let holder = SCNNode()
            holder.name = "ar_lights"

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 260
            holder.addChildNode(ambient)

            let sun = SCNNode()
            let l = SCNLight()
            l.type = .directional
            l.intensity = 420
            // Always on here, unlike the screen stage: without the contact shadow the character
            // does not read as standing on the real floor at all.
            l.castsShadow = true
            l.shadowMode = .deferred
            l.shadowColor = UIColor(white: 0, alpha: 0.4)
            l.shadowRadius = 6
            l.shadowSampleCount = DeviceTier.shadowSampleCount
            sun.light = l
            sun.eulerAngles = SCNVector3(-Float.pi / 2.4, Float.pi / 10, 0)
            holder.addChildNode(sun)

            arView.scene.rootNode.addChildNode(holder)
        }

        /// An invisible disc under the feet that exists only to catch the character's shadow.
        ///
        /// The rig already casts one, but after placement the only other geometry in the scene -
        /// the detected plane visualisations - is hidden, so the shadow fell on nothing and the
        /// character read as a sticker floating over the camera feed. Writing no colour keeps the
        /// real floor visible through it while still receiving the shadow.
        private func addShadowCatcher(to container: SCNNode, height h: Float) {
            let size = CGFloat(max(h, 0.8) * 1.8)
            let plane = SCNPlane(width: size, height: size)
            let m = plane.firstMaterial!
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            m.colorBufferWriteMask = []
            m.writesToDepthBuffer = false
            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -Float.pi / 2
            node.castsShadow = false
            node.renderingOrder = -10
            container.addChildNode(node)
        }

        /// Yaw the placement so the character looks at the viewer.
        ///
        /// A horizontal raycast returns a transform aligned to the world axes, not to wherever the
        /// user happens to be standing, so the character was just as likely to be placed with its
        /// back turned. Only the Y rotation is taken - tilting a dancer would look wrong.
        private func facingCamera(_ hit: simd_float4x4, from camera: simd_float4x4) -> simd_float4x4 {
            let target = simd_float3(hit.columns.3.x, hit.columns.3.y, hit.columns.3.z)
            let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            var d = eye - target
            d.y = 0
            guard simd_length(d) > 1e-4 else { return hit }
            // The character faces +Z once normalizeOrientation has squared it up, which is why the
            // screen stage parks its camera on the +Z side.
            let yaw = atan2(d.x, d.z)
            var t = matrix_identity_float4x4
            t.columns.3 = hit.columns.3
            return t * simd_float4x4(simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0)))
        }

        /// ARSCNViewDelegate callbacks arrive on SceneKit's renderer thread, so the placement result
        /// has to be handed back on the main thread. Calling straight through left SwiftUI state set
        /// off-main: the character was placed, but the view never re-rendered and its placement
        /// guidance stayed on screen.
        private func notifyPlaced(_ node: SCNNode) {
            // --- 触感反馈：角色落地 ---
            HapticManager.medium()

            // --- 视觉优化：淡入与缩放动画 ---
            let finalScale = node.simdScale
            node.simdScale = .zero
            node.opacity = 0

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.6
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            node.simdScale = finalScale
            node.opacity = 1.0
            SCNTransaction.commit()

            guard let onPlaced else { return }
            if Thread.isMainThread { onPlaced(node) }
            else { DispatchQueue.main.async { onPlaced(node) } }
        }

        /// Undo the mutations AR made to the shared character node, so the screen stage gets it back
        /// exactly as it was handed over.
        func restoreCharacter() {
            container?.removeFromParentNode()
            guard let root = controller.characterRoot else { return }
            if groundOffset != 0 {
                root.simdPosition.y += groundOffset
                groundOffset = 0
            }
            root.removeFromParentNode()
            controller.reattachToScreenScene()
        }

        // MARK: Reticle
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

        /// Each frame, attach the reticle to the ground hit by the screen center.
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

        // MARK: Gesture Handlers

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let container, placed else { return }
            if g.state == .changed {
                let s = Float(g.scale)
                container.simdScale *= s
                g.scale = 1.0 // 增量缩放

                // --- 触感反馈：缩放过程中 ---
                HapticManager.light()
            }
        }

        @objc func handleRotate(_ g: UIRotationGestureRecognizer) {
            guard let container, placed else { return }
            if g.state == .changed {
                container.simdEulerAngles.y -= Float(g.rotation)
                g.rotation = 0 // 增量旋转

                // --- 触感反馈：旋转过程中 ---
                HapticManager.light()
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView, let container, placed else { return }
            let pt = g.location(in: arView)

            // 沿平面滑动移动
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)

            if let q = query, let hit = arView.session.raycast(q).first {
                // 平移时不改变旋转和缩放
                container.simdWorldPosition = simd_float3(hit.worldTransform.columns.3.x,
                                                         hit.worldTransform.columns.3.y,
                                                         hit.worldTransform.columns.3.z)
            }
        }

        // MARK: Tap to place -> Create ARAnchor
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            let pt = g.location(in: arView)
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
            guard let q = query, let hit = arView.session.raycast(q).first else {
                print("[AR] tap at \(pt) hit no surface - keep scanning")
                return
            }
            guard container != nil else {
                // setup() ran before the model finished installing, so there is nothing to place.
                print("[AR] tap ignored: no character container (model was not ready at setup)")
                return
            }
            let camera = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
            let transform = facingCamera(hit.worldTransform, from: camera)
            // Already placed = move: direct translation; Not yet placed = add anchor
            if placed, let container {
                container.simdWorldTransform = transform
            } else {
                let anchor = ARAnchor(name: "placement", transform: transform)
                arView.session.add(anchor: anchor)
            }
        }

        // MARK: Plane visualization + Anchor placement
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
            // Our placement anchor: Attach the character to the anchor node (follow the anchor = stay fixed on the ground)
            if anchor.name == "placement", let container, !placed {
                container.removeFromParentNode()
                node.addChildNode(container)
                container.simdPosition = .zero
                container.isHidden = false
                placed = true
                reticle?.isHidden = true
                // Hide plane grids after placement to avoid obstruction
                planeNodes.values.forEach { $0.isHidden = true }
                notifyPlaced(container)
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
