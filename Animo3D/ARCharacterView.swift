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
    /// Called when a tap found no floor, so the caller can say so instead of leaving the user
    /// tapping a screen that never answers.
    var onPlacementMissed: (() -> Void)? = nil
    var holder: SceneHolder? = nil
    /// true = land on the floor after scanning the ground; false = no ground detection, place directly in front of the camera (for quick validation).
    var detectGround: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onAttach: onAttach, onPlaced: onPlaced,
                    onPlacementMissed: onPlacementMissed, detectGround: detectGround)
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

            // People Occlusion, so a real person can pass in front of the character.
            // Needs an A12 or newer; iOS 16's depth is markedly more accurate than iOS 13's.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
                print("[AR] People Occlusion enabled")
            } else {
                print("[AR] People Occlusion not supported on this device")
            }

            arView.session.run(config)

            if detectGround {
                // No ARCoachingOverlayView here. It was added as a full-screen subview with
                // `activatesAutomatically = true`, so whenever a plane had not been found yet - which
                // is exactly when the user is tapping to try - it sat on top of the ARSCNView and
                // swallowed every touch before the tap recogniser below could see it. That is the
                // "no plane found, and tapping does nothing" report: one symptom, one cause.
                // The app already has its own guidance (ARCoachView), which is non-interactive.
                let tap = UITapGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.handleTap(_:)))
                arView.addGestureRecognizer(tap)

                // Move, scale and rotate the placed character.
                // Scale
                let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
                arView.addGestureRecognizer(pinch)

                // Rotate
                let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
                arView.addGestureRecognizer(rotate)

                // Drag to move
                let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
                pan.maximumNumberOfTouches = 1   // one finger only, so it cannot fight the two-finger gestures
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
        private let onPlacementMissed: (() -> Void)?
        private let detectGround: Bool
        private weak var arView: ARSCNView?
        private var container: SCNNode?      // Carries the character: scaling + sole alignment
        private var reticle: SCNNode?        // Ground reticle
        private var planeNodes: [UUID: SCNNode] = [:]
        private(set) var placed = false
        /// Whether the screen centre is currently over a usable floor. Published so the SwiftUI
        /// guidance can say "tap to place" only when a tap will actually do something.
        private(set) var hasFloor = false
        /// The scale the character was placed at. The pinch limits are relative to this, so they
        /// mean the same thing whatever size the model came in at.
        private(set) var placedScale: Float = 1
        /// How far the character was pushed down so its feet sit on the container origin. Kept so
        /// leaving AR can put it back - the screen stage shares the same node.
        private var groundOffset: Float = 0

        init(controller: CharacterSceneController, onAttach: (() -> Void)?,
             onPlaced: ((SCNNode) -> Void)?, onPlacementMissed: (() -> Void)?, detectGround: Bool) {
            self.controller = controller
            self.onAttach = onAttach
            self.onPlaced = onPlaced
            self.onPlacementMissed = onPlacementMissed
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
            HapticManager.medium()          // one tick as the character lands

            // Fade and scale in, so it arrives rather than appearing.
            let finalScale = node.simdScale
            placedScale = max(finalScale.x, 0.0001)
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

        /// Floor distances that count as a place someone meant to point at.
        ///
        /// An `.estimatedPlane` raycast with few feature points will happily return a hit tens of
        /// metres away, and placing there put the character somewhere the user never aimed - it then
        /// reads as "I tapped far away and it appeared right in front", because a character 30m off
        /// is a speck and the next tap lands somewhere else entirely. Anything outside this range is
        /// treated as no hit at all.
        private static let placementRange: ClosedRange<Float> = 0.35...6.0

        /// One raycast, used by both the reticle and the tap, so what the reticle shows is exactly
        /// where a tap lands. They used to differ - the reticle only ever asked for an estimated
        /// plane while the tap preferred real plane geometry - so the two could resolve to different
        /// surfaces at different distances.
        private func floorHit(at point: CGPoint, in arView: ARSCNView) -> ARRaycastResult? {
            let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane]
            guard let camera = arView.session.currentFrame?.camera.transform else { return nil }
            let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)

            for target in targets {
                guard let q = arView.raycastQuery(from: point, allowing: target, alignment: .horizontal),
                      let hit = arView.session.raycast(q).first else { continue }
                let p = simd_float3(hit.worldTransform.columns.3.x,
                                    hit.worldTransform.columns.3.y,
                                    hit.worldTransform.columns.3.z)
                if Self.placementRange.contains(simd_distance(p, eye)) { return hit }
            }
            return nil
        }

        /// Each frame, attach the reticle to the ground under the screen centre.
        ///
        /// The reticle being visible is the contract: it means a tap will land, and its absence
        /// means a tap will not. `handleTap` checks the same thing rather than guessing.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard detectGround, !placed, let arView, let reticle else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = floorHit(at: center, in: arView) else {
                reticle.isHidden = true
                hasFloor = false
                return
            }
            reticle.simdWorldTransform = hit.worldTransform
            reticle.isHidden = false
            hasFloor = true
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

        /// How far the character may be scaled, as a multiple of the size it was placed at.
        ///
        /// Unbounded before: a pinch could shrink it to nothing or blow it up past the far plane,
        /// with no way back other than replacing it.
        private static let scaleRange: ClosedRange<Float> = 0.35...3.0

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let container, placed else { return }
            guard g.state == .changed else {
                // One tick at the start and one at the end, which is what a gesture should feel
                // like. Firing on every `.changed` ran the motor continuously for the whole pinch.
                if g.state == .began || g.state == .ended { HapticManager.light() }
                return
            }
            let proposed = container.simdScale.x * Float(g.scale)
            let clamped = min(max(proposed, placedScale * Self.scaleRange.lowerBound),
                              placedScale * Self.scaleRange.upperBound)
            container.simdScale = simd_float3(repeating: clamped)
            g.scale = 1.0                       // incremental
        }

        @objc func handleRotate(_ g: UIRotationGestureRecognizer) {
            guard let container, placed else { return }
            guard g.state == .changed else {
                if g.state == .began || g.state == .ended { HapticManager.light() }
                return
            }
            container.simdEulerAngles.y -= Float(g.rotation)
            g.rotation = 0                      // incremental
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView, let container, placed else { return }
            let pt = g.location(in: arView)

            // Slide along the detected floor. An existing plane is preferred; an estimated one is
            // the fallback while ARKit is still resolving the surface.
            let query = arView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .horizontal)
                ?? arView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .horizontal)

            if let q = query, let hit = arView.session.raycast(q).first {
                // Position only: rotation and scale are the other two gestures' business.
                container.simdWorldPosition = simd_float3(hit.worldTransform.columns.3.x,
                                                          hit.worldTransform.columns.3.y,
                                                          hit.worldTransform.columns.3.z)
            }
        }

        // MARK: Tap to place -> Create ARAnchor
        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            guard container != nil else {
                // setup() ran before the model finished installing, so there is nothing to place.
                print("[AR] tap ignored: no character container (model was not ready at setup)")
                return
            }
            let pt = g.location(in: arView)
            guard let hit = floorHit(at: pt, in: arView) else {
                // Silent before: a tap that found nothing printed to the console and the user was
                // left tapping a screen that never responded.
                print("[AR] tap at \(pt) found no floor within range")
                onPlacementMissed?()
                return
            }
            let camera = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
            let transform = facingCamera(hit.worldTransform, from: camera)

            if placed, let container {
                // Position and yaw only. Assigning `simdWorldTransform` also wrote the matrix's
                // scale, and `facingCamera` returns a unit-scale matrix - so every tap-to-move
                // silently threw away the `1.3 / modelHeight` normalisation and the character
                // jumped in size, which reads as it lurching towards the camera.
                let keptScale = container.simdScale
                container.simdWorldTransform = transform
                container.simdScale = keptScale
                HapticManager.light()
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
