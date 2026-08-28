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
    var holder: SceneHolder? = nil
    /// true = land on the floor after scanning the ground; false = no ground detection, place directly in front of the camera (for quick validation).
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
        private var container: SCNNode?      // Carries the character: scaling + sole alignment
        private var reticle: SCNNode?        // Ground reticle
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
            if minY.isFinite { root.simdPosition.y -= minY }
            container = c

            if detectGround {
                c.isHidden = true          // Display only after placement; don't attach to scene yet, attach to anchor node during placement
                placed = false
                addReticle(arView)
            } else {
                c.simdPosition = simd_float3(0, -0.8, -1.6)
                c.isHidden = false
                placed = true
                arView.scene.rootNode.addChildNode(c)
            }
            print("[AR] model ready height=\(h) scale=\(s) groundOffset=\(minY) detectGround=\(detectGround)")
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

        // MARK: Tap to place -> Create ARAnchor
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            let pt = g.location(in: arView)
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)
            guard let q = query, let hit = arView.session.raycast(q).first else { return }
            // Already placed = move: direct translation; Not yet placed = add anchor
            if placed, let container {
                container.simdWorldTransform = hit.worldTransform
            } else {
                let anchor = ARAnchor(name: "placement", transform: hit.worldTransform)
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
