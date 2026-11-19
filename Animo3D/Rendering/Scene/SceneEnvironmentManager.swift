//
//  SceneEnvironmentManager.swift
//  Animo3D
//
//  Lighting, environment, sky, ground, shadows and procedural texture rendering for 3D stage views.
//

import SwiftUI
import SceneKit
import UIKit

final class SceneEnvironmentManager {

    private unowned let scene: SCNScene

    private var backdropNode: SCNNode?
    private var backdropPlane: SCNPlane?
    private var backdropAspect: Float = 0
    private var backdropRefilling = false

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private var footShadows: [SCNNode] = []
    private var skylineNode: SCNNode?
    private var inlayNode: SCNNode?

    private weak var keyLight: SCNLight?
    private weak var fillLight: SCNLight?
    private weak var rimLight: SCNLight?
    private weak var sunLight: SCNLight?
    private weak var sunNode: SCNNode?

    private(set) var feetY: Float = 0
    private(set) var stageCenter: simd_float3 = .zero
    private(set) var rimTint: UIColor?

    init(scene: SCNScene) {
        self.scene = scene
    }

    func setRimTint(_ color: UIColor?, stage: StageSpec) {
        self.rimTint = color
        rimLight?.color = color ?? stage.lightLevels.rimColor
    }

    func setupLights(lightsAdded: inout Bool, characterRoot: SCNNode?) {
        guard !lightsAdded else { return }
        lightsAdded = true

        // StageSpec supplies the intensities after setup. Keep the calibrated light types,
        // positions and cone angles: nearby omni lights flatten skin and pale clothing.
        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .spot
        keyLight.spotInnerAngle = 35
        keyLight.spotOuterAngle = 75
        keyLight.attenuationStartDistance = 5
        keyLight.attenuationEndDistance = 25
        key.light = keyLight
        key.position = SCNVector3(-3, 6, 6)
        key.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(key)
        self.keyLight = keyLight

        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.color = UIColor(red: 0.9, green: 0.95, blue: 1, alpha: 1)
        fill.light = fillLight
        fill.position = SCNVector3(5, 2, 4)
        scene.rootNode.addChildNode(fill)
        self.fillLight = fillLight

        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .spot
        rimLight.spotInnerAngle = 45
        rimLight.spotOuterAngle = 90
        rim.light = rimLight
        rim.position = SCNVector3(0, 5, -8)
        rim.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(rim)
        self.rimLight = rimLight

        let sun = SCNNode()
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.castsShadow = DeviceTier.dynamicShadows
        sunLight.shadowMode = .forward
        sunLight.shadowRadius = 8
        sunLight.shadowSampleCount = DeviceTier.shadowSampleCount
        sunLight.shadowColor = UIColor(white: 0, alpha: 0.45)
        sun.light = sunLight
        sun.position = SCNVector3(0, 5, 0)
        scene.rootNode.addChildNode(sun)
        self.sunLight = sunLight
        self.sunNode = sun
    }

    func applyLightLevels(stage: StageSpec, lightLevels: StageSpec.LightLevels, characterRoot: SCNNode?) {
        let l = lightLevels
        characterRoot?.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.setValue(l.rimShader, forKey: "rimStrength") }
        }
        keyLight?.color = l.keyColor
        rimLight?.color = rimTint ?? l.rimColor
        sunNode?.simdEulerAngles = stage.sunEuler
        keyLight?.intensity = l.key
        fillLight?.intensity = l.fill
        rimLight?.intensity = l.rim
        sunLight?.intensity = l.sun
        sunLight?.shadowColor = UIColor(white: 0, alpha: l.shadowAlpha)
        scene.lightingEnvironment.contents =
            l.ibl > 0 ? (stage.environment?() ?? CharacterSceneView.studioEnvironment) : nil
        scene.lightingEnvironment.intensity = l.ibl
    }

    func updateBackgroundAndGround(stage: StageSpec, groundEnabled: Bool, contactShadowOnly: Bool, modelHeight: Float, characterRoot: SCNNode?, cameraNode: SCNNode?, viewportAspect: Float, humanoidNode: (String) -> SCNNode?, syncCameraControl: () -> Void, applyCameraGrade: () -> Void) {
        scene.background.contents = groundEnabled
            ? (stage.backdrop != nil ? stage.horizon : stage.sky())
            : nil

        if groundEnabled {
            let h = max(modelHeight, 1)
            scene.fogColor = stage.horizon
            scene.fogStartDistance = CGFloat(h * stage.fogNear)
            scene.fogEndDistance = CGFloat(h * stage.fogFar)
            scene.fogDensityExponent = 1.5
        } else {
            scene.fogEndDistance = 0
        }
        if let root = characterRoot {
            setupGround(root, stage: stage, groundEnabled: groundEnabled, contactShadowOnly: contactShadowOnly, modelHeight: modelHeight, cameraNode: cameraNode, viewportAspect: viewportAspect, humanoidNode: humanoidNode)
        }
        setupBackdrop(stage: stage, groundEnabled: groundEnabled, cameraNode: cameraNode, viewportAspect: viewportAspect, modelHeight: modelHeight)
        syncCameraControl()
        applyLightLevels(stage: stage, lightLevels: stage.lightLevels, characterRoot: characterRoot)
        applyCameraGrade()
    }

    func setupBackdrop(stage: StageSpec, groundEnabled: Bool, cameraNode: SCNNode?, viewportAspect: Float, modelHeight: Float) {
        backdropNode?.removeFromParentNode(); backdropNode = nil
        backdropPlane = nil
        guard groundEnabled, let make = stage.backdrop, let picture = make(), let cameraNode
        else { backdropAspect = 0; return }

        let aspect = max(viewportAspect, 0.3)
        let plane = SCNPlane(width: 1, height: 1)
        let m = plane.firstMaterial!
        m.diffuse.contents = StageImage.filling(picture, aspect: CGFloat(aspect))
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.diffuse.mipFilter = .linear

        let node = SCNNode(geometry: plane)
        node.castsShadow = false
        cameraNode.addChildNode(node)
        backdropNode = node
        backdropPlane = plane
        backdropAspect = aspect
        fitBackdrop(cameraNode: cameraNode, viewportAspect: viewportAspect, modelHeight: modelHeight, stage: stage, groundEnabled: groundEnabled)
    }

    func fitBackdrop(cameraNode: SCNNode?, viewportAspect: Float, modelHeight: Float, stage: StageSpec, groundEnabled: Bool) {
        guard let node = backdropNode, let plane = backdropPlane,
              let cameraNode, let camera = cameraNode.camera else { return }

        let h = max(modelHeight, 0.1)
        let distance = min(h * 5.5, Float(camera.zFar) * 0.8)

        let aspect = max(viewportAspect, 0.3)
        let fov = Float(camera.fieldOfView) * .pi / 180
        let vertical = camera.projectionDirection == .horizontal
            ? 2 * atan(tan(fov / 2) / aspect)
            : fov
        let frameH = 2 * distance * tan(vertical / 2) * 1.04
        let frameW = frameH * aspect * 1.04

        if abs(Float(plane.height) - frameH) > frameH * 0.001
            || abs(Float(plane.width) - frameW) > frameW * 0.001 {
            plane.width = CGFloat(frameW)
            plane.height = CGFloat(frameH)
            node.simdPosition = simd_float3(0, 0, -distance)
        }

        if abs(aspect - backdropAspect) > 0.02 && !backdropRefilling {
            backdropRefilling = true
            Task { @MainActor [weak self] in
                self?.setupBackdrop(stage: stage, groundEnabled: groundEnabled, cameraNode: cameraNode, viewportAspect: viewportAspect, modelHeight: modelHeight)
                self?.backdropRefilling = false
            }
        }
    }

    private func setupGround(_ root: SCNNode, stage: StageSpec, groundEnabled: Bool, contactShadowOnly: Bool, modelHeight: Float, cameraNode: SCNNode?, viewportAspect: Float, humanoidNode: (String) -> SCNNode?) {
        guard groundEnabled || contactShadowOnly else {
            floorNode?.removeFromParentNode(); floorNode = nil
            backdropNode?.removeFromParentNode(); backdropNode = nil
            contactShadow?.removeFromParentNode(); contactShadow = nil
            footShadows.forEach { $0.removeFromParentNode() }; footShadows = []
            skylineNode?.removeFromParentNode(); skylineNode = nil
            inlayNode?.removeFromParentNode(); inlayNode = nil
            return
        }
        var minY = Float.greatestFiniteMagnitude
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] { for y in [Float(a.y), Float(b.y)] { for z in [Float(a.z), Float(b.z)] {
                let w = node.simdConvertPosition(simd_float3(x, y, z), to: nil)
                minY = min(minY, w.y)
                minX = min(minX, w.x); maxX = max(maxX, w.x)
                minZ = min(minZ, w.z); maxZ = max(maxZ, w.z)
            }}}
        }
        guard minY.isFinite else { return }
        feetY = minY
        let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
        let footSpan = max(maxX - minX, 0.001)

        if let sun = sunLight {
            let h = max(modelHeight, 0.1)
            sun.orthographicScale = CGFloat(h * 1.6)
            sun.zNear = 0.05
            sun.zFar = CGFloat(h * 12)
            sun.shadowRadius = 2.5
            if let node = sunNode { followPerformer(node, height: h) }
        }

        floorNode?.removeFromParentNode()
        inlayNode?.removeFromParentNode(); inlayNode = nil

        let h = max(modelHeight, 0.1)
        if let spec = stage.ground {
            let ground = SCNPlane(width: CGFloat(h * spec.extent), height: CGFloat(h * spec.extent))
            let gm = ground.firstMaterial!
            gm.diffuse.contents = spec.texture()
            gm.diffuse.wrapS = .repeat
            gm.diffuse.wrapT = .repeat
            gm.diffuse.contentsTransform = SCNMatrix4MakeScale(spec.repeats, spec.repeats, 1)
            gm.diffuse.mipFilter = .linear
            gm.diffuse.maxAnisotropy = 8
            gm.lightingModel = .lambert
            gm.isDoubleSided = false
            gm.multiply.contents = spec.tint

            let gnode = SCNNode(geometry: ground)
            gnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            gnode.simdPosition = simd_float3(0, minY, 0)
            scene.rootNode.addChildNode(gnode)
            floorNode = gnode

            if let inlayTexture = spec.inlay {
                let inlay = SCNPlane(width: CGFloat(h * spec.inlayExtent), height: CGFloat(h * spec.inlayExtent))
                let im = inlay.firstMaterial!
                im.diffuse.contents = inlayTexture()
                im.lightingModel = .lambert
                im.multiply.contents = spec.tint
                im.isDoubleSided = false
                im.writesToDepthBuffer = false
                let inode = SCNNode(geometry: inlay)
                inode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                inode.simdPosition = simd_float3(cx, minY + 0.002, cz)
                inode.renderingOrder = 1
                inode.castsShadow = false
                scene.rootNode.addChildNode(inode)
                inlayNode = inode
            }
        }

        contactShadow?.removeFromParentNode(); contactShadow = nil
        footShadows.forEach { $0.removeFromParentNode() }; footShadows = []
        if !groundEnabled {
            let blobW = min(footSpan * 2.4, max(modelHeight, 0.1) * 0.75) * 1.15
            let blob = SCNPlane(width: CGFloat(blobW), height: CGFloat(blobW * 0.62))
            let bm = blob.firstMaterial!
            bm.diffuse.contents = Self.contactShadowTextureStrong
            bm.transparency = 0.8
            bm.lightingModel = .constant
            bm.isDoubleSided = true
            bm.writesToDepthBuffer = false
            let bnode = SCNNode(geometry: blob)
            bnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            bnode.simdPosition = simd_float3(cx, minY + 0.003, cz)
            bnode.renderingOrder = 2
            scene.rootNode.addChildNode(bnode)
            contactShadow = bnode
            followFeet(bnode, groundY: minY + 0.003, humanoidNode: humanoidNode, modelHeight: modelHeight)
            addFootContact(groundY: minY + 0.0045, span: footSpan, humanoidNode: humanoidNode, modelHeight: modelHeight)
        }

        stageCenter = simd_float3(cx, 0, cz)
        if let ring = stage.skyline {
            addSkyline(ring, feetY: minY, height: max(modelHeight, 0.1))
        } else {
            skylineNode?.removeFromParentNode(); skylineNode = nil
        }
    }

    private func followPerformer(_ node: SCNNode, height: Float) {
        // Updated when performer moves
    }

    private func followFeet(_ node: SCNNode, groundY: Float, humanoidNode: (String) -> SCNNode?, modelHeight: Float) {
        guard let lf = humanoidNode("leftFoot") ?? humanoidNode("leftAnkle"),
              let rf = humanoidNode("rightFoot") ?? humanoidNode("rightAnkle") else { return }
        let restAnkleY = (lf.simdWorldPosition.y + rf.simdWorldPosition.y) / 2
        let fade = max(0.05, modelHeight * 0.10)

        node.constraints = [SCNTransformConstraint(inWorldSpace: true) { [weak lf, weak rf] _, m in
            guard let lf, let rf else { return m }
            let l = lf.simdWorldPosition, r = rf.simdWorldPosition
            let lower = l.y <= r.y ? l : r
            let cx = (lower.x * 2 + l.x + r.x) / 4
            let cz = (lower.z * 2 + l.z + r.z) / 4
            let t = min(1, max(0, min(l.y, r.y) - restAnkleY) / fade)
            let k = 1 + t * 0.3
            var m = SCNMatrix4MakeScale(k, k, k)
            m = SCNMatrix4Mult(m, SCNMatrix4MakeRotation(-Float.pi / 2, 1, 0, 0))
            return SCNMatrix4Mult(m, SCNMatrix4MakeTranslation(cx, groundY, cz))
        }]
    }

    private func addFootContact(groundY: Float, span: Float, humanoidNode: (String) -> SCNNode?, modelHeight: Float) {
        let radius = min(span * 0.75, max(modelHeight, 0.1) * 0.22)
        for boneName in ["leftFoot", "rightFoot"] {
            guard let footNode = humanoidNode(boneName) else { continue }
            let plane = SCNPlane(width: CGFloat(radius * 1.8), height: CGFloat(radius * 2.2))
            let m = plane.firstMaterial!
            m.diffuse.contents = Self.contactShadowTextureStrong
            m.transparency = 0.9
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            let node = SCNNode(geometry: plane)
            node.renderingOrder = 3
            node.constraints = [SCNTransformConstraint(inWorldSpace: true) { [weak footNode] _, _ in
                guard let footNode else { return SCNMatrix4Identity }
                let pos = footNode.simdWorldPosition
                var m = SCNMatrix4MakeRotation(-Float.pi / 2, 1, 0, 0)
                m = SCNMatrix4Mult(m, SCNMatrix4MakeTranslation(pos.x, groundY, pos.z))
                return m
            }]
            scene.rootNode.addChildNode(node)
            footShadows.append(node)
        }
    }

    private func addSkyline(_ spec: StageSpec.Skyline, feetY: Float, height h: Float) {
        skylineNode?.removeFromParentNode()

        let radius = h * spec.radius
        let band = h * spec.band
        let repeats = spec.repeats
        let segments = 96

        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], uvs: [CGPoint] = []
        var idx: [Int32] = []
        for i in 0...segments {
            let t = Float(i) / Float(segments)
            let a = t * 2 * .pi
            let x = sin(a) * radius, z = cos(a) * radius
            let inward = SCNVector3(-sin(a), 0, -cos(a))
            verts.append(SCNVector3(x, band, z));  norms.append(inward)
            verts.append(SCNVector3(x, 0, z));     norms.append(inward)
            uvs.append(CGPoint(x: CGFloat(t * repeats), y: 0))
            uvs.append(CGPoint(x: CGFloat(t * repeats), y: 1))
            if i < segments {
                let b = Int32(i * 2)
                idx += [b, b + 1, b + 3, b, b + 3, b + 2]
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts),
                                        SCNGeometrySource(normals: norms),
                                        SCNGeometrySource(textureCoordinates: uvs)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])

        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = spec.texture()
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        geo.materials = [m]

        let node = SCNNode(geometry: geo)
        node.simdPosition = simd_float3(stageCenter.x, feetY, stageCenter.z)
        node.castsShadow = false
        node.renderingOrder = -20
        scene.rootNode.addChildNode(node)
        skylineNode = node
    }

    static let contactShadowTextureStrong: UIImage = makeContactShadowImage(0.8)

    private static func makeContactShadowImage(_ alpha: CGFloat) -> UIImage {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let colors = [UIColor(white: 0, alpha: alpha).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                             endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
    }
}
