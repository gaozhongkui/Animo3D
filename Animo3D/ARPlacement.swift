//
//  ARPlacement.swift
//  Animo3D
//
//  The parts of "put this thing on the real floor" that are identical whether the thing is a
//  dancing character or a static model from the community feed.
//
//  Extracted rather than copied. The placement logic had already gone wrong twice in one file, in
//  ways a second copy would have inherited: the reticle asked for an estimated plane while the tap
//  preferred real plane geometry, so the two resolved to different surfaces and the character
//  landed somewhere the reticle had never pointed; and an unbounded raycast happily returned a hit
//  tens of metres away, which put the model somewhere nobody aimed.
//

import ARKit
import SceneKit

enum ARPlacement {
    /// Floor distances that count as somewhere a person meant to point at.
    ///
    /// An `.estimatedPlane` raycast with few feature points will return a hit far outside this
    /// range, and placing there reads as "I tapped near me and it appeared on the horizon".
    static let range: ClosedRange<Float> = 0.35...6.0

    /// One raycast, used by both the reticle and the tap, so what the reticle shows is exactly where
    /// a tap lands. Real plane geometry is preferred; an estimated plane is the fallback while
    /// ARKit is still resolving the surface.
    static func floorHit(at point: CGPoint, in arView: ARSCNView) -> ARRaycastResult? {
        guard let camera = arView.session.currentFrame?.camera.transform else { return nil }
        let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)

        for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
            guard let q = arView.raycastQuery(from: point, allowing: target, alignment: .horizontal),
                  let hit = arView.session.raycast(q).first else { continue }
            let p = simd_float3(hit.worldTransform.columns.3.x,
                                hit.worldTransform.columns.3.y,
                                hit.worldTransform.columns.3.z)
            if range.contains(simd_distance(p, eye)) { return hit }
        }
        return nil
    }

    /// Yaw a placement so the model looks at the viewer.
    ///
    /// A horizontal raycast returns a transform aligned to the world axes, not to wherever the user
    /// happens to be standing, so without this a model is just as likely to be placed with its back
    /// turned. Only the Y rotation is taken - tilting it would look wrong.
    static func facingCamera(_ hit: simd_float4x4, from camera: simd_float4x4) -> simd_float4x4 {
        let target = simd_float3(hit.columns.3.x, hit.columns.3.y, hit.columns.3.z)
        let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        var d = eye - target
        d.y = 0
        guard simd_length(d) > 1e-4 else { return hit }
        let yaw = atan2(d.x, d.z)
        var t = matrix_identity_float4x4
        t.columns.3 = hit.columns.3
        return t * simd_float4x4(simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0)))
    }

    /// How far a placed model may be scaled, as a multiple of the size it was placed at. Unbounded
    /// before, so a pinch could shrink it to nothing or blow it past the far plane with no way back.
    static let scaleRange: ClosedRange<Float> = 0.35...3.0

    /// A modest, predictable rig for an AR scene.
    ///
    /// Environment texturing needs an A12 and a settled probe, so without these a model can come
    /// out black on older devices or right after launch. The directional light always casts: without
    /// a contact shadow the model does not read as standing on the real floor at all.
    static func addLights(to arView: ARSCNView) {
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

    /// An invisible disc under the model that exists only to catch its shadow.
    ///
    /// The rig casts one, but after placement the only other geometry in the scene - the detected
    /// plane visualisations - is hidden, so the shadow would fall on nothing and the model would
    /// read as a sticker over the camera feed. Writing no colour keeps the real floor visible
    /// through it while still receiving the shadow.
    static func addShadowCatcher(to container: SCNNode, size s: Float) {
        let side = CGFloat(max(s, 0.8) * 1.8)
        let plane = SCNPlane(width: side, height: side)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.writesToDepthBuffer = false
        m.colorBufferWriteMask = []
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -Float.pi / 2
        node.castsShadow = false
        node.renderingOrder = -10
        container.addChildNode(node)
    }

    /// A ring-and-dot reticle that marks where a tap will land.
    static func makeReticle() -> SCNNode {
        let ring = SCNTorus(ringRadius: 0.14, pipeRadius: 0.006)
        ring.firstMaterial?.diffuse.contents = UIColor.systemGreen
        ring.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: ring)
        let dot = SCNNode(geometry: SCNSphere(radius: 0.012))
        dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
        dot.geometry?.firstMaterial?.lightingModel = .constant
        node.addChildNode(dot)
        node.isHidden = true
        return node
    }

    /// The lowest point of a node's geometry, expressed in `space`. Used to sit a model on the
    /// container's origin so its base lands on the floor rather than through it.
    static func lowestY(of root: SCNNode, in space: SCNNode) -> Float {
        var minY = Float.greatestFiniteMagnitude
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] {
                for y in [Float(a.y), Float(b.y)] {
                    for z in [Float(a.z), Float(b.z)] {
                        minY = min(minY, node.simdConvertPosition(simd_float3(x, y, z), to: space).y)
                    }
                }
            }
        }
        return minY
    }
}
