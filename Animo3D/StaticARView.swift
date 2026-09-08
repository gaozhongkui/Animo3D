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

struct StaticARView: UIViewRepresentable {
    /// A local USDZ (or SCN) file, already downloaded.
    let url: URL
    /// Roughly how tall the model should stand, in metres. Community models arrive at wildly
    /// different scales - some authored in centimetres, some the size of a building - so the file's
    /// own units cannot be trusted and it is normalised to something a room can hold.
    var targetHeight: Float = 1.0
    var onPlaced: (() -> Void)? = nil
    var onPlacementMissed: (() -> Void)? = nil
    /// Every tap on the view, whether or not it placed anything. `onPlaced` and
    /// `onPlacementMissed` between them miss the one case where feedback matters most: a model that
    /// failed to load leaves nothing to place, so neither fires and the screen looks inert.
    var onTapped: (() -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, targetHeight: targetHeight, onPlaced: onPlaced,
                    onPlacementMissed: onPlacementMissed, onTapped: onTapped)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true
        arView.autoenablesDefaultLighting = false
        arView.delegate = context.coordinator
        context.coordinator.setup(arView)

        if ARWorldTrackingConfiguration.isSupported {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
            }
            arView.session.run(config)

            // No ARCoachingOverlayView: it is a full-screen subview that swallows every touch while
            // it is up, which is exactly when the user is tapping to place. The app's own guidance
            // is non-interactive.
            let c = context.coordinator
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
        uiView.session.pause()
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        private let url: URL
        private let targetHeight: Float
        private let onPlaced: (() -> Void)?
        private let onPlacementMissed: (() -> Void)?
        private let onTapped: (() -> Void)?

        private weak var arView: ARSCNView?
        private var container: SCNNode?
        private var reticle: SCNNode?
        private var planeNodes: [UUID: SCNNode] = [:]
        private(set) var placed = false
        private var placedScale: Float = 1

        init(url: URL, targetHeight: Float, onPlaced: (() -> Void)?,
             onPlacementMissed: (() -> Void)?, onTapped: (() -> Void)?) {
            self.url = url
            self.targetHeight = targetHeight
            self.onPlaced = onPlaced
            self.onPlacementMissed = onPlacementMissed
            self.onTapped = onTapped
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
            model.removeAllAnimations()
            model.enumerateChildNodes { n, _ in n.removeAllAnimations() }

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
