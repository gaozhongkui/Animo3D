//
//  StaticARView.swift
//  Animo3D
//
//  AR for a model that does not dance: the USDZ files from the community feed.
//
//  Separate from `ARCharacterView` on purpose. Before placement the two are the same job - scan,
//  reticle, tap, drag, pinch, rotate - and everything they share now lives in `ARPlacement`. After
//  placement they have nothing in common: a character has a skeleton to drive, feet to keep on the
//  floor, and effects hanging off it, while one of these is a static mesh. Folding a rigless model
//  into `ARCharacterView` would have meant a controller with no skeleton threading `nil` through
//  the retargeter, the foot planter and the VFX installer - which is the kind of one-class-two-jobs
//  arrangement this file exists to avoid.
//
//  It hands its `ARSCNView` to the shared `SceneHolder`, so `SceneViewRecorder` records it exactly
//  the way it records the dance stage - per-frame `snapshot()`, watermark burned in.
//

import SwiftUI
import ARKit
import SceneKit

enum StaticViewMode { case ar, turntable }

struct StaticARView: UIViewRepresentable {
    /// A local USDZ (or SCN) file, already downloaded.
    let url: URL
    /// How large the model may be, in metres, along its longest axis. Community models arrive at
    /// wildly different scales - some authored in centimetres, some the size of a building - so the
    /// file's own units cannot be trusted and it is normalised to something a room can hold.
    ///
    /// 1.6 m, not 1 m. At 1 m a person comes out waist-high and a wide creature comes out tiny: the
    /// dragon's metre of wingspan left it 28 cm tall, which reads as a toy rather than as the thing
    /// the user opened the model to see. 1.6 m puts a human at near life size and still fits a
    /// dragon in a living room, and the pinch range either side of it spans 0.56 m to 4.8 m.
    var targetHeight: Float = 1.6
    /// `.ar` puts the model on the real floor; `.turntable` spins it against a plain background.
    ///
    /// The turntable is not only a fallback for devices without ARKit - it is a mode the user can
    /// pick, and it is how you tell the two halves of this screen apart. If a model looks right on
    /// the turntable and wrong in AR, the model and its download are fine and the problem is
    /// placement; if it looks wrong in both, it is the file or the way it is being loaded.
    var mode: StaticViewMode = .ar
    var onPlaced: (() -> Void)? = nil
    var onPlacementMissed: (() -> Void)? = nil
    /// Every tap on the view, whether or not it placed anything. `onPlaced` and
    /// `onPlacementMissed` between them miss the one case where feedback matters most: a model that
    /// failed to load leaves nothing to place, so neither fires and the screen looks inert.
    var onTapped: (() -> Void)? = nil
    /// True while Apple's scanning overlay is on screen. The app's own guidance and status line
    /// stay out of the way while it is up, so the user is not being told two things at once.
    var onCoaching: ((Bool) -> Void)? = nil
    /// A short reason tracking is unhealthy, or nil when it is fine.
    var onTrackingHint: ((String?) -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, targetHeight: targetHeight, onPlaced: onPlaced,
                    onPlacementMissed: onPlacementMissed, onTapped: onTapped,
                    onCoaching: onCoaching, onTrackingHint: onTrackingHint)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = false
        arView.delegate = context.coordinator
        context.coordinator.setup(arView)

        if mode == .ar, ARWorldTrackingConfiguration.isSupported {
            arView.session.run(ARPlacement.makeConfiguration())

            let c = context.coordinator
            c.beginCoaching(on: arView)
            let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
            arView.addGestureRecognizer(tap)
            let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
            arView.addGestureRecognizer(pinch)
            let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.handleRotate(_:)))
            arView.addGestureRecognizer(rotate)
            let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            arView.addGestureRecognizer(pan)
        } else {
            // Either the user asked for the turntable, or this device has no ARKit - which includes
            // the Simulator, where `isSupported` is false, no session runs, there is no camera feed
            // and none of the gesture recognisers above are even registered. Without this branch
            // the screen was blank forever: the model starts hidden and is only revealed on
            // placement, which can never happen.
            //
            // `ARSCNView` is an `SCNView`, so it renders an ordinary scene perfectly well; the
            // model sits at the origin and spins instead of standing on a real floor.
            context.coordinator.showTurntable(in: arView)
        }

        holder?.scnView = arView
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.endCoaching()          // invalidates the timer; it would outlive the view
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate, ARCoachingOverlayViewDelegate {
        private let url: URL
        private let targetHeight: Float
        private let onPlaced: (() -> Void)?
        private let onPlacementMissed: (() -> Void)?
        private let onTapped: (() -> Void)?
        private let onCoaching: ((Bool) -> Void)?
        private let onTrackingHint: ((String?) -> Void)?

        private weak var arView: ARSCNView?
        private var container: SCNNode?
        private var reticle: SCNNode?
        private var planeNodes: [UUID: SCNNode] = [:]
        private weak var coaching: ARCoachingOverlayView?
        private var coachingTimer: Timer?
        private(set) var placed = false
        private var placedScale: Float = 1

        init(url: URL, targetHeight: Float, onPlaced: (() -> Void)?,
             onPlacementMissed: (() -> Void)?, onTapped: (() -> Void)?,
             onCoaching: ((Bool) -> Void)?, onTrackingHint: ((String?) -> Void)?) {
            self.url = url
            self.targetHeight = targetHeight
            self.onPlaced = onPlaced
            self.onPlacementMissed = onPlacementMissed
            self.onTapped = onTapped
            self.onCoaching = onCoaching
            self.onTrackingHint = onTrackingHint
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            ARPlacement.addLights(to: arView)

            guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: true]) else {
                print("[StaticAR] cannot open \(url.lastPathComponent)")
                return
            }
            let model = SCNNode()
            for child in loaded.rootNode.childNodes { model.addChildNode(child) }

            // Play whatever the author baked in, on a loop.
            //
            // This used to call `removeAllAnimations()`, on the assumption behind this file's name:
            // community models are the rigless ones, the dancing is our retargeter's job. That is
            // wrong for a large slice of the feed - "Black Dragon with Idle Animation" arrives with
            // a 696-bone skeleton and a clip called `Dragon_Idle`, and stripping it left a model
            // standing frozen when the animation is the thing the user picked it for. It costs
            // nothing to keep: it is the author's own clip driving the author's own skeleton, with
            // no retargeting involved.
            //
            // The loop has to be set explicitly - an imported clip plays once and then stops, which
            // for an idle reads as the model freezing a few seconds after it appears.
            model.enumerateHierarchy { n, _ in
                for key in n.animationKeys {
                    guard let player = n.animationPlayer(forKey: key) else { continue }
                    player.animation.repeatCount = .greatestFiniteMagnitude
                    player.animation.autoreverses = false
                    player.play()
                }
            }

            // First, before anything touches the GPU: a community model's textures are whatever
            // the author exported, and 2048s add up to more memory than a phone running ARKit has
            // to spare. 1024 on a normal device, 512 where memory is already tight.
            let cap = DeviceTier.isLowEnd ? 512 : 1024
            let shrunk = ARPlacement.shrinkTextures(in: model, maxPixel: cap)
            if shrunk > 0 { print("[StaticAR] capped \(shrunk) texture(s) at \(cap)px") }

            // Then: a backdrop slab would both drive the scale and then sit on the real floor as a
            // dark plate.
            let stripped = ARPlacement.stripBackdrops(from: model)
            if stripped > 0 { print("[StaticAR] dropped \(stripped) backdrop mesh(es)") }

            let c = SCNNode()
            c.addChildNode(model)

            // Fit inside a `targetHeight` cube, then sit the base on the container origin. Both
            // steps measure the model rather than trusting the file's declared units: community
            // USDZs routinely say centimetres and mean something else.
            //
            // The divisor is the *largest* axis, not the height. Normalising height alone is fine
            // for a person, whose height is their largest axis anyway, but a dragon is far wider
            // than it is tall - making it a metre tall gave it a 3.6 m wingspan, which does not
            // fit in a room. "Fits in a 1 m cube" holds for both.
            let (lo, hi) = ARPlacement.visibleBounds(of: model, in: c)
            let extent = hi - lo
            let longest = max(extent.x, max(extent.y, extent.z))
            if longest > 0.0001 {
                let s = targetHeight / longest
                model.simdScale = simd_float3(repeating: s)
                model.simdPosition.y -= lo.y * s
            }
            container = c
            ARPlacement.addShadowCatcher(to: c, size: targetHeight)

            c.isHidden = true                 // shown when it is standing somewhere
            let r = ARPlacement.makeReticle()
            arView.scene.rootNode.addChildNode(r)
            reticle = r
        }

        /// Show the model on a slow turntable, for when there is no AR session to place it in.
        func showTurntable(in arView: ARSCNView) {
            guard let container else { return }
            reticle?.removeFromParentNode(); reticle = nil

            container.isHidden = false
            container.simdPosition = .zero
            arView.scene.rootNode.addChildNode(container)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.01
            // Framed off the model's own size, so a dragon and a figurine are both in shot.
            let reach = max(targetHeight, 0.1) * 1.9
            camera.simdPosition = simd_float3(0, targetHeight * 0.55, reach)
            camera.look(at: SCNVector3(0, targetHeight * 0.38, 0))
            arView.scene.rootNode.addChildNode(camera)
            arView.pointOfView = camera
            arView.backgroundColor = .black
            arView.allowsCameraControl = true      // drag to look around, since there is no walking

            container.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 18)))

            placed = true                          // the shutter and the recorder behave as normal
            if Thread.isMainThread { onPlaced?() }
            else { DispatchQueue.main.async { self.onPlaced?() } }
            onCoaching?(false)
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

        // MARK: Reticle

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard !placed, let arView, let reticle else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = ARPlacement.floorHit(at: center, in: arView) else {
                reticle.isHidden = true
                return
            }
            reticle.simdWorldTransform = hit.worldTransform
            reticle.isHidden = false
        }

        // MARK: Anchors

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            if let plane = anchor as? ARPlaneAnchor {
                // A plane exists, so the scanning guidance has done its job.
                endCoaching()
                let g = SCNPlane(width: CGFloat(plane.planeExtent.width),
                                 height: CGFloat(plane.planeExtent.height))
                g.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.18)
                g.firstMaterial?.isDoubleSided = true
                let p = SCNNode(geometry: g)
                p.eulerAngles.x = -Float.pi / 2
                p.simdPosition = simd_float3(plane.center.x, 0, plane.center.z)
                node.addChildNode(p)
                planeNodes[plane.identifier] = p
                return
            }
            guard anchor.name == "placement", let container, !placed else { return }
            container.removeFromParentNode()
            node.addChildNode(container)
            container.simdPosition = .zero
            container.isHidden = false
            placedScale = max(container.simdScale.x, 0.0001)
            placed = true
            reticle?.isHidden = true
            planeNodes.values.forEach { $0.isHidden = true }
            HapticManager.medium()
            if Thread.isMainThread { onPlaced?() }
            else { DispatchQueue.main.async { self.onPlaced?() } }
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let plane = anchor as? ARPlaneAnchor,
                  let p = planeNodes[plane.identifier], let g = p.geometry as? SCNPlane else { return }
            g.width = CGFloat(plane.planeExtent.width)
            g.height = CGFloat(plane.planeExtent.height)
            p.simdPosition = simd_float3(plane.center.x, 0, plane.center.z)
        }

        // MARK: Gestures

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            onTapped?()          // before every early return below
            guard let arView, container != nil else { return }
            let pt = g.location(in: arView)
            guard let hit = ARPlacement.floorHit(at: pt, in: arView) else {
                onPlacementMissed?()
                return
            }
            let camera = arView.session.currentFrame?.camera.transform ?? matrix_identity_float4x4
            let transform = ARPlacement.facingCamera(hit.worldTransform, from: camera)

            if placed, let container {
                // Position and yaw only. Assigning `simdWorldTransform` also writes the matrix's
                // scale, and `facingCamera` returns a unit-scale matrix, so a tap-to-move would
                // throw away the height normalisation and the model would jump in size.
                let keptScale = container.simdScale
                container.simdWorldTransform = transform
                container.simdScale = keptScale
                HapticManager.light()
            } else {
                arView.session.add(anchor: ARAnchor(name: "placement", transform: transform))
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let container, placed else { return }
            guard g.state == .changed else {
                // One tick at each end, which is what a gesture should feel like. Firing on every
                // `.changed` runs the motor continuously for the whole pinch.
                if g.state == .began || g.state == .ended { HapticManager.light() }
                return
            }
            let proposed = container.simdScale.x * Float(g.scale)
            let clamped = min(max(proposed, placedScale * ARPlacement.scaleRange.lowerBound),
                              placedScale * ARPlacement.scaleRange.upperBound)
            container.simdScale = simd_float3(repeating: clamped)
            g.scale = 1.0
        }

        @objc func handleRotate(_ g: UIRotationGestureRecognizer) {
            guard let container, placed else { return }
            guard g.state == .changed else {
                if g.state == .began || g.state == .ended { HapticManager.light() }
                return
            }
            container.simdEulerAngles.y -= Float(g.rotation)
            g.rotation = 0
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let arView, let container, placed else { return }
            guard let hit = ARPlacement.floorHit(at: g.location(in: arView), in: arView) else { return }
            container.simdWorldPosition = simd_float3(hit.worldTransform.columns.3.x,
                                                      hit.worldTransform.columns.3.y,
                                                      hit.worldTransform.columns.3.z)
        }
    }
}
