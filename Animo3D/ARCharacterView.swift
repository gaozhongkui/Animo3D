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
    /// Called every time the character lands on an anchor - the first placement and every
    /// tap-to-move after it. The retargeter's reference pose is tied to an absolute world position,
    /// so it has to be re-established here or the body stays where it was first captured.
    var onRelocated: (() -> Void)? = nil
    /// True while Apple's scanning overlay holds the screen.
    var onCoaching: ((Bool) -> Void)? = nil
    /// A short reason tracking is unhealthy, or nil when it is fine.
    var onTrackingHint: ((String?) -> Void)? = nil
    var holder: SceneHolder? = nil
    /// true = land on the floor after scanning the ground; false = no ground detection, place directly in front of the camera (for quick validation).
    var detectGround: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onAttach: onAttach, onPlaced: onPlaced,
                    onPlacementMissed: onPlacementMissed, detectGround: detectGround,
                    onCoaching: onCoaching, onTrackingHint: onTrackingHint,
                    onRelocated: onRelocated)
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
            // Shared with the community AR screen, so both get LiDAR scene reconstruction and
            // scene depth where the device has them - neither asked for either before.
            arView.session.run(ARPlacement.makeConfiguration(detectGround: detectGround))

            if detectGround {
                // Apple's scanning guidance, shown until the first plane or a 15s timeout. It is
                // manually driven precisely because leaving it to `activatesAutomatically` is what
                // let it hold the screen forever in a room ARKit could not read - see
                // ARPlacement.installCoaching.
                context.coordinator.beginCoaching(on: arView)

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
        coordinator.endCoaching()          // invalidates the timer; it would outlive the view
        uiView.session.pause()
        coordinator.restoreCharacter()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARCoachingOverlayViewDelegate {
        private let controller: CharacterSceneController
        private let onAttach: (() -> Void)?
        private let onPlaced: ((SCNNode) -> Void)?
        private let onPlacementMissed: (() -> Void)?
        private let onRelocated: (() -> Void)?
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
        private var horizontalOffset = simd_float3(0, 0, 0)
        private let onCoaching: ((Bool) -> Void)?
        private let onTrackingHint: ((String?) -> Void)?
        private weak var coaching: ARCoachingOverlayView?
        private var coachingTimer: Timer?
        /// When the first frame arrived, and whether automatic placement has been asked for.
        private var firstFrame: TimeInterval?
        private var autoPlaceRequested = false

        init(controller: CharacterSceneController, onAttach: (() -> Void)?,
             onPlaced: ((SCNNode) -> Void)?, onPlacementMissed: (() -> Void)?, detectGround: Bool,
             onCoaching: ((Bool) -> Void)?, onTrackingHint: ((String?) -> Void)?,
             onRelocated: (() -> Void)?) {
            self.controller = controller
            self.onAttach = onAttach
            self.onPlaced = onPlaced
            self.onPlacementMissed = onPlacementMissed
            self.detectGround = detectGround
            self.onCoaching = onCoaching
            self.onTrackingHint = onTrackingHint
            self.onRelocated = onRelocated
        }

        // MARK: Session health

        /// Show Apple's scanning guidance, and arm the timeout that guarantees it goes away.
        func beginCoaching(on arView: ARSCNView) {
            let overlay = ARPlacement.installCoaching(on: arView, delegate: self)
            coaching = overlay
            overlay.setActive(true, animated: true)
            onCoaching?(true)
            coachingTimer = Timer.scheduledTimer(withTimeInterval: ARPlacement.coachingTimeout,
                                                 repeats: false) { [weak self] _ in
                self?.endCoaching()
            }
        }

        /// Called on the first detected plane, on timeout, and on teardown. Idempotent.
        func endCoaching() {
            coachingTimer?.invalidate(); coachingTimer = nil
            guard let overlay = coaching, overlay.isActive else { return }
            overlay.setActive(false, animated: true)
        }

        func coachingOverlayViewDidDeactivate(_ v: ARCoachingOverlayView) {
            coachingTimer?.invalidate(); coachingTimer = nil
            onCoaching?(false)
        }

        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            onTrackingHint?(ARPlacement.trackingHint(for: camera.trackingState))
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            ARPlacement.addLights(to: arView)
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
            // The feet land at the container origin, and the body stands over it.
            //
            // Vertical alone was not enough: the root arrives carrying whatever transform it had in
            // the screen scene, where it is positioned to suit that scene's framing rather than
            // sitting on the origin. Left as-is, the anchor lands exactly where the user tapped and
            // the character stands a stride to one side of it - which reads as the placement having
            // missed. Only the horizontal centre is moved; the vertical is the sole-on-the-floor
            // offset, and the two must not be conflated.
            let bounds = ARPlacement.visibleBounds(of: root, in: c)
            if bounds.lo.y.isFinite {
                root.simdPosition.y -= bounds.lo.y
                groundOffset = bounds.lo.y
            }
            if bounds.lo.x.isFinite && bounds.hi.x.isFinite {
                root.simdPosition.x -= (bounds.lo.x + bounds.hi.x) / 2
                root.simdPosition.z -= (bounds.lo.z + bounds.hi.z) / 2
                horizontalOffset = simd_float3((bounds.lo.x + bounds.hi.x) / 2, 0,
                                               (bounds.lo.z + bounds.hi.z) / 2)
            }
            container = c
            ARPlacement.addShadowCatcher(to: c, size: h)

            if detectGround {
                c.isHidden = true          // Display only after placement; don't attach to scene yet, attach to anchor node during placement
                placed = false
                let r = ARPlacement.makeReticle()
                arView.scene.rootNode.addChildNode(r)
                reticle = r
            } else {
                c.simdPosition = simd_float3(0, -0.8, -1.6)
                c.isHidden = false
                placed = true
                arView.scene.rootNode.addChildNode(c)
                publishGround(c)
                notifyPlaced(c)
            }
            print(String(format: "[AR] model ready height=%.2f scale=%.3f groundOffset=%.3f "
                         + "centred by (%.3f, %.3f) detectGround=%@",
                         h, s, groundOffset, horizontalOffset.x, horizontalOffset.z,
                         detectGround ? "yes" : "no"))
        }




        /// Tell the retargeter which plane to plant the feet on.
        ///
        /// The container's origin *is* the ground here: `root.simdPosition.y -= minY` at mount puts
        /// the rest-pose soles exactly on it. Without this the retargeter keeps planting against
        /// `CharacterSceneController.feetY`, which was measured off the bounding box in the screen
        /// scene - a different world origin, and a different scale, since AR normalises the
        /// character to 1.3m. That mismatch is a fixed vertical offset for the whole performance,
        /// which is the character hanging in the air above the plane it was placed on.
        private func publishGround(_ container: SCNNode) {
            let p = container.simdWorldPosition
            controller.arGroundY = p.y
            print(String(format: "[AR] placed at (%.3f, %.3f, %.3f), ground y = %.3f", p.x, p.y, p.z, p.y))
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
            if horizontalOffset != .zero {
                root.simdPosition.x += horizontalOffset.x
                root.simdPosition.z += horizontalOffset.z
                horizontalOffset = .zero
            }
            root.removeFromParentNode()
            controller.reattachToScreenScene()
        }



        /// Each frame, attach the reticle to the ground under the screen centre.
        ///
        /// The reticle being visible is the contract: it means a tap will land, and its absence
        /// means a tap will not. `handleTap` checks the same thing rather than guessing.
        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard detectGround, !placed, let arView else { return }

            // Same reasoning as StaticARView: the character starts hidden and was only revealed by
            // a tap that found a floor, so in a room ARKit cannot read it was never revealed at
            // all. Two seconds is long enough for a plane to turn up if one is going to; after
            // that the character goes in front of the camera and a tap still re-places it.
            if firstFrame == nil { firstFrame = time }
            // Only ever auto-place onto a floor that actually exists. The old rule was "after two
            // seconds, place it somewhere" - and two seconds is nowhere near long enough for ARKit
            // to find a plane, so in practice it always took the `inFrontOfCamera` branch and hung
            // the character in mid-air a metre and a half ahead of the phone, at waist height. That
            // is the "it shows up in front of me instead of where I tapped" report: by the time the
            // green reticle appeared the character was already placed, and `placed` is what stops
            // the reticle updating and what makes `didAdd` ignore the anchor a tap creates.
            //
            // So: wait for a floor, however long that takes. The coaching overlay is on screen the
            // whole time telling the user to move the phone, and a tap places it the moment the
            // reticle shows. `hasFloor` is set below from the same raycast a tap would use.
            if let start = firstFrame, time - start > 2.0, hasFloor, !autoPlaceRequested,
               container != nil {
                autoPlaceRequested = true
                DispatchQueue.main.async { [weak self] in self?.placeAutomatically(in: arView) }
            }

            guard let reticle else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = ARPlacement.floorHit(at: center, in: arView) else {
                reticle.isHidden = true
                hasFloor = false
                return
            }
            reticle.simdWorldTransform = hit.worldTransform
            reticle.isHidden = false
            hasFloor = true
        }


        // MARK: Gesture Handlers


        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let container, placed else { return }
            guard g.state == .changed else {
                // One tick at the start and one at the end, which is what a gesture should feel
                // like. Firing on every `.changed` ran the motor continuously for the whole pinch.
                if g.state == .began || g.state == .ended { HapticManager.light() }
                return
            }
            let proposed = container.simdScale.x * Float(g.scale)
            let clamped = min(max(proposed, placedScale * ARPlacement.scaleRange.lowerBound),
                              placedScale * ARPlacement.scaleRange.upperBound)
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
            guard let hit = ARPlacement.floorHit(at: pt, in: arView) else {
                // Silent before: a tap that found nothing printed to the console and the user was
                // left tapping a screen that never responded.
                print("[AR] tap at \(pt) found no floor within range")
                onPlacementMissed?()
                return
            }
            let camera = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
            let transform = ARPlacement.facingCamera(hit.worldTransform, from: camera)

            // One path for both cases: add an anchor and let `didAdd` re-parent onto it. Moving the
            // container by hand kept it attached to the *previous* anchor, so ARKit went on
            // correcting that anchor's pose underneath it and the character drifted off the spot it
            // had just been put on.
            arView.session.add(anchor: ARAnchor(name: "placement", transform: transform))
            HapticManager.light()
        }

        /// Place the character on a floor if there is one, and straight ahead if there is not.
        private func placeAutomatically(in arView: ARSCNView) {
            guard !placed, container != nil,
                  let camera = arView.session.currentFrame?.camera else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            let h = max(controller.modelHeight, 0.1)
            let transform: simd_float4x4
            if let hit = ARPlacement.floorHit(at: center, in: arView) {
                transform = ARPlacement.facingCamera(hit.worldTransform, from: camera.transform)
            } else if detectGround {
                // Nothing to stand on yet. Standing in the air is worse than not being there, and
                // it also locks out the tap that would have got this right - so give the frame
                // callback its trigger back and let it ask again.
                autoPlaceRequested = false
                print("[AR] auto-place skipped: no floor under the reticle yet")
                return
            } else {
                transform = ARPlacement.inFrontOfCamera(camera.transform,
                                                        distance: max(1.8, h * 1.5),
                                                        drop: 0.6)
                print("[AR] ground detection off - placed ahead of the camera")
            }
            endCoaching()
            arView.session.add(anchor: ARAnchor(name: "placement", transform: transform))
        }

        // MARK: Plane visualization + Anchor placement
        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            if let plane = anchor as? ARPlaneAnchor {
                // A plane exists, so the scanning guidance has done its job.
                endCoaching()
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
            //
            // `!placed` used to gate this, which silently threw away every anchor after the first.
            // A tap that raced the automatic placement therefore did nothing at all - the anchor
            // was created, ARKit delivered it here, and the branch declined it because the
            // character was already standing somewhere else. Re-parenting to the newer anchor is
            // the whole point of the tap; the scale is the container's own and survives.
            if anchor.name == "placement", let container {
                let wasPlaced = placed
                container.removeFromParentNode()
                node.addChildNode(container)
                container.simdPosition = .zero
                container.simdOrientation = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
                container.isHidden = false
                placed = true
                reticle?.isHidden = true
                // Hide plane grids after placement to avoid obstruction
                planeNodes.values.forEach { $0.isHidden = true }
                publishGround(container)
                // Re-base the retargeter here, not on attach. Its reference pose carries an
                // absolute world hip position, so a capture taken before the character was anchored
                // pins the body to wherever it was hidden - in front of the camera - however far
                // away the anchor is. Runs on every placement, because tap-to-move has exactly the
                // same problem as the first placement.
                DispatchQueue.main.async { [weak self] in self?.onRelocated?() }
                if !wasPlaced { notifyPlaced(container) }
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
