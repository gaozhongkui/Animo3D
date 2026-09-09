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
    /// The model could not be opened. Reported rather than swallowed: before this the screen simply
    /// stayed empty with a reticle and no explanation, which is indistinguishable from "AR is
    /// broken" to the person holding the phone.
    var onLoadFailed: (() -> Void)? = nil
    /// A one-line description of what the AR session is actually doing, refreshed about once a
    /// second. Surfaced on screen when the model has not appeared, because "AR does not work" is
    /// not something that can be debugged and "model loaded, 0 planes, tracking limited:
    /// insufficient features, not placed" is.
    var onDiagnostics: ((String) -> Void)? = nil
    /// The heaviest mesh's bone count, reported as soon as the model is open, so the screen can
    /// decide whether AR is a mode this model can actually be seen in.
    var onBoneCount: ((Int) -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, targetHeight: targetHeight, onPlaced: onPlaced,
                    onPlacementMissed: onPlacementMissed, onTapped: onTapped,
                    onCoaching: onCoaching, onTrackingHint: onTrackingHint,
                    onLoadFailed: onLoadFailed, onDiagnostics: onDiagnostics,
                    onBoneCount: onBoneCount)
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
        private let onLoadFailed: (() -> Void)?
        private let onDiagnostics: ((String) -> Void)?
        private let onBoneCount: ((Int) -> Void)?

        private weak var arView: ARSCNView?
        private var container: SCNNode?
        private var reticle: SCNNode?
        private var planeNodes: [UUID: SCNNode] = [:]
        private weak var coaching: ARCoachingOverlayView?
        private var coachingTimer: Timer?
        private(set) var placed = false
        private var placedScale: Float = 1
        /// When the first frame arrived, and whether the automatic placement has been asked for.
        private var firstFrame: TimeInterval?
        private var autoPlaceRequested = false
        /// Diagnostics state: enough to say which step did not happen.
        private var modelLoaded = false
        private var fittedNote = "-"
        private var placeRoute = "-"
        private var lastDiagnostics: TimeInterval = 0

        init(url: URL, targetHeight: Float, onPlaced: (() -> Void)?,
             onPlacementMissed: (() -> Void)?, onTapped: (() -> Void)?,
             onCoaching: ((Bool) -> Void)?, onTrackingHint: ((String?) -> Void)?,
             onLoadFailed: (() -> Void)?, onDiagnostics: ((String) -> Void)?,
             onBoneCount: ((Int) -> Void)?) {
            self.url = url
            self.targetHeight = targetHeight
            self.onPlaced = onPlaced
            self.onPlacementMissed = onPlacementMissed
            self.onTapped = onTapped
            self.onCoaching = onCoaching
            self.onTrackingHint = onTrackingHint
            self.onLoadFailed = onLoadFailed
            self.onDiagnostics = onDiagnostics
            self.onBoneCount = onBoneCount
        }

        func setup(_ arView: ARSCNView) {
            self.arView = arView
            ARPlacement.addLights(to: arView)

            guard let c = ARPlacement.loadCommunityModel(url: url, fitting: targetHeight) else {
                modelLoaded = false
                onLoadFailed?()
                return
            }
            modelLoaded = true
            let bones = ARPlacement.lastLoadMaxBones
            DispatchQueue.main.async { self.onBoneCount?(bones) }
            let (blo, bhi) = ARPlacement.visibleBounds(of: c, in: c)
            let e = bhi - blo
            fittedNote = String(format: "%.2f x %.2f x %.2f m", e.x, e.y, e.z)
            container = c
            ARPlacement.addShadowCatcher(to: c, size: targetHeight)

            c.isHidden = true                 // shown when it is standing somewhere
            let r = ARPlacement.makeReticle()
            arView.scene.rootNode.addChildNode(r)
            reticle = r
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
            guard !placed, let arView else { return }

            // Show the model without waiting to be asked, and without waiting for a plane.
            //
            // The model used to start hidden and be revealed only by a tap that found a floor. In a
            // room ARKit cannot read - dark, plain carpet, a phone held still - that tap never
            // succeeds, so the model was never revealed and the screen stayed empty. Every other
            // fix in this file was invisible behind that one condition.
            //
            // A couple of seconds is enough for ARKit to offer a plane if it is going to. After
            // that, put the model in front of the camera regardless. A tap still re-places it, and
            // once a real floor turns up the tap snaps to it.
            if firstFrame == nil { firstFrame = time }
            if let start = firstFrame, time - start > 2.0, !autoPlaceRequested, container != nil {
                autoPlaceRequested = true
                DispatchQueue.main.async { [weak self] in self?.placeAutomatically(in: arView) }
            }

            if time - lastDiagnostics > 1.0 {
                lastDiagnostics = time
                emitDiagnostics(arView)
            }

            guard let reticle else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            guard let hit = ARPlacement.floorHit(at: center, in: arView) else {
                reticle.isHidden = true
                return
            }
            reticle.simdWorldTransform = hit.worldTransform
            reticle.isHidden = false
        }

        /// Everything needed to tell which step failed, in one line.
        private func emitDiagnostics(_ arView: ARSCNView) {
            guard let onDiagnostics else { return }
            let frame = arView.session.currentFrame
            let planes = frame?.anchors.compactMap { $0 as? ARPlaneAnchor }.count ?? 0
            let tracking: String
            switch frame?.camera.trackingState {
            case .normal: tracking = "normal"
            case .notAvailable: tracking = "unavailable"
            case .limited(let r):
                switch r {
                case .initializing: tracking = "limited/initializing"
                case .excessiveMotion: tracking = "limited/motion"
                case .insufficientFeatures: tracking = "limited/features"
                case .relocalizing: tracking = "limited/relocalizing"
                @unknown default: tracking = "limited/?"
                }
            case nil: tracking = "no frame"
            @unknown default: tracking = "?"
            }
            var lines = ["model: \(modelLoaded ? "loaded \(fittedNote)" : "FAILED TO LOAD")",
                         ARPlacement.lastLoadSummary,
                         "tracking: \(tracking)   planes: \(planes)",
                         "placed: \(placed ? "yes via \(placeRoute)" : "no")"]
            if placed, let container, let cam = frame?.camera {
                let p = container.simdWorldPosition
                let eye = simd_float3(cam.transform.columns.3.x, cam.transform.columns.3.y,
                                      cam.transform.columns.3.z)
                lines.append(String(format: "hidden: %@   %.2f m away",
                                    container.isHidden ? "YES" : "no", simd_distance(p, eye)))
            }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { onDiagnostics(text) }
        }

        /// Place the model on a floor if there is one, and straight ahead if there is not.
        private func placeAutomatically(in arView: ARSCNView) {
            guard !placed, container != nil,
                  let camera = arView.session.currentFrame?.camera else { return }
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            let transform: simd_float4x4
            if let hit = ARPlacement.floorHit(at: center, in: arView) {
                transform = ARPlacement.facingCamera(hit.worldTransform, from: camera.transform)
                placeRoute = "plane"
            } else {
                placeRoute = "ahead-of-camera"
                // Far enough out that a 1.6 m model is not inside the near plane, and a little
                // below eye level so it reads as standing rather than floating at face height.
                transform = ARPlacement.inFrontOfCamera(camera.transform,
                                                        distance: max(1.6, targetHeight * 1.15),
                                                        drop: 0.55)
                print("[StaticAR] no plane yet - placed ahead of the camera")
            }
            endCoaching()
            arView.session.add(anchor: ARAnchor(name: "placement", transform: transform))
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
