//
//  CharacterSceneView.swift
//  Animo3D
//
//  SceneKit 3D character container: Loads rigged models, locates bone nodes,
//  stops built-in animations (now driven by BlazePose), and automatically frames based on model dimensions.
//

import SwiftUI
import SceneKit
import Combine

final class CharacterSceneController: ObservableObject {

    enum BackgroundType: String, CaseIterable {
        case studio, sky
    }

    let scene = SCNScene()
    private(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // Character unit height (for AR scaling)
    private(set) var scheme: BoneScheme = .mixamo   // Bone naming scheme (Mixamo / VRM)
    var isVRM: Bool { boneNodes["J_Bip_C_Hips"] != nil }   // VRoid uses full animation JSON for playback
    var groundEnabled = false   // Ground + top-down view enabled only for large performance view; disabled for thumbnails/small cards
    var contactShadowOnly = false   // Detail page: Only add contact shadow under feet (to give grounding sense), no dark floor
    var portraitMode = false    // Static display (thumbnails/character details): Strikes an A-pose to avoid skinning collapse in T-pose in SceneKit
    private var lightsAdded = false

    @Published var backgroundType: BackgroundType = .studio {
        didSet { updateBackgroundAndGround() }
    }

    // Skeletal pose at load time (includes A-pose for portraitMode), used for resetting.
    private var bindPose: [(node: SCNNode, orientation: simd_quatf, position: simd_float3)] = []

    private func captureBindPose() {
        bindPose = boneNodes.values.map { ($0, $0.simdOrientation, $0.simdPosition) }
    }

    /// Reset to the skeletal pose at load time.
    /// When reusing the same controller to render thumbnails for multiple dances consecutively, you must reset first, otherwise PoseRetargeter
    /// will sample the pose of the previous dance as the "rest pose", causing poses to become increasingly distorted.
    func resetToRestPose() {
        for b in bindPose {
            b.node.simdOrientation = b.orientation
            b.node.simdPosition = b.position
        }
    }

    /// Attach the character root node back to this controller's screen scene (used when switching back from AR).
    func reattachToScreenScene() {
        guard let root = characterRoot else { return }
        if root.parent !== scene.rootNode {
            root.removeFromParentNode()
            scene.rootNode.addChildNode(root)
        }
    }

    /// Load model from App bundle (.usdz/.scn/.dae). Returns discovered Mixamo bone names.
    /// Note: This is the synchronous version, which parses a 10~60MB model file on the calling thread.
    /// Calling from the main thread will cause significant lag; prefer the two-step `loadSceneFile` + `install` approach.
    @discardableResult
    func loadModel(named filename: String) -> [String] {
        guard let loaded = Self.loadSceneFile(named: filename) else { return [] }
        return install(loaded)
    }

    /// Only performs disk parsing, doesn't touch any on-screen scenes — can be called on background threads.
    /// Models are often 10~60MB; parsing + texture decoding + creating skinner takes hundreds of ms to seconds on iPhone X,
    /// and is the main reason for "lag when entering the stage page" if on the main thread.
    static func loadSceneFile(named filename: String, warmUp: Bool = false) -> SCNScene? {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base,
                                        withExtension: ext.isEmpty ? nil : ext) else {
            print("[Character] model file not found: \(filename)")
            return nil
        }
        guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
            print("[Character] failed to load model: \(url.lastPathComponent)")
            return nil
        }
        if warmUp { Self.warmUp(loaded) }
        return loaded
    }

    /// Warm up: Pre-upload geometry and textures to the GPU.
    /// Without this, textures are decoded and uploaded during the **first frame render**, causing a lag when first entering the stage page.
    /// prepare is a synchronous blocking call and should only be used on background threads.
    static func warmUp(_ scene: SCNScene) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        _ = r.prepare(scene.rootNode, shouldAbortBlock: nil)   // Synchronous, blocking variant
    }

    /// Install the pre-parsed scene into this controller (lightweight, main thread).
    @discardableResult
    func install(_ loaded: SCNScene) -> [String] {
        // Reuse the same scene: Remove the old character first to avoid accumulating characters/memory with each switch (root cause of crashing after several switches on physical devices)
        characterRoot?.removeFromParentNode()
        boneNodes.removeAll()
        isLoaded = false

        // Do not clone: Cloning skinned nodes breaks SCNSkinner's bone references (especially noticeable on iOS 16,
        // manifesting as mesh collapse or stretched triangles). Use the loaded root node directly.
        let root = loaded.rootNode
        scene.rootNode.addChildNode(root)
        characterRoot = root

        // Collect bone nodes and completely remove built-in baked animations (otherwise animations will play themselves and fight for bone control)
        var found: [String] = []
        var animCount = 0
        root.removeAllAnimations()
        root.enumerateChildNodes { node, _ in
            animCount += node.animationKeys.count
            for key in node.animationKeys { node.removeAnimation(forKey: key) }
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
            }
        }
        print("[Character] cleared built-in animations keys=\(animCount)")
        // Bone naming scheme: VRoid(VRM) uses J_Bip_ prefix, otherwise Mixamo
        scheme = (boneNodes["J_Bip_C_Hips"] != nil) ? .vrm : .mixamo
        print("[Character] bone scheme: \(boneNodes["J_Bip_C_Hips"] != nil ? "VRM" : "Mixamo")")
        if boneNodes["J_Bip_C_Hips"] != nil { applyToonShading(root) }
        if portraitMode { applyPortraitPose() }
        normalizeOrientation(root)
        setupFrontCamera()

        // Fallback height calculation: When bone recognition fails (e.g., Tripo static mesh without Mixamo bones),
        // traverse all geometries, convert the 8 corners of each local bounding box to world coordinates to find the true AABB.
        // Using root.boundingBox directly is unreliable: it might not include child nodes or account for import scale.
        if modelHeight <= 0.01 {
            modelHeight = worldBoundingHeight(root)
            print(String(format: "[Character] fallback bounding-box height=%.3f", modelHeight))
        }

        if !lightsAdded { addLights(); lightsAdded = true }
        updateBackgroundAndGround()   // setupGround is called internally; don't call it separately (previously ground/shadow textures were created twice per load)
        captureBindPose()
        isLoaded = true
        print("[Character] loaded, found \(found.count) Mixamo bones")
        return found.sorted()
    }

    func updateBackgroundAndGround() {
        var fog: UIColor
        switch backgroundType {
        case .studio:
            scene.background.contents = UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
            fog = UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)   // = Background color, seamless at horizon
        case .sky:
            if let skyImage = UIImage(named: "sky_park") {
                scene.background.contents = skyImage
            } else {
                scene.background.contents = CharacterSceneView.skyBackdrop()
            }
            fog = UIColor(red: 0.82, green: 0.88, blue: 0.95, alpha: 1)   // = Sky horizon color
        }
        // Fog: Ground fades into background in the distance -> Seamless fusion of ground and background, creating depth and grounding (only for large performance view)
        if groundEnabled {
            let h = max(modelHeight, 1)
            scene.fogColor = fog
            // The sky stage needs the fog much closer: without it the ground plane runs to a hard
            // horizon line against the sky image. The studio keeps the longer, subtler falloff.
            // Must start beyond the performer (roughly 2.3 body heights from the camera) or the
            // fog washes the character out along with the ground.
            let near: Float = backgroundType == .sky ? 3.0 : 2.2
            let far: Float = backgroundType == .sky ? 9.0 : 6.5
            scene.fogStartDistance = CGFloat(h * near)
            scene.fogEndDistance = CGFloat(h * far)
            scene.fogDensityExponent = 1.5
        } else {
            scene.fogEndDistance = 0
        }
        if let root = characterRoot {
            setupGround(root)
        }
    }

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private var stageRig: SCNNode?              // Spotlight beams + floor light pool (studio stage only)
    private weak var ambientLight: SCNLight?    // Dimmed while the stage rig is lit, so the mood stays dark
    private weak var keyLight: SCNLight?
    private weak var sunLight: SCNLight?
    private(set) var feetY: Float = 0   // World Y of feet (for VFX ground positioning)

    /// Ground: Visible floor (with slight reflection) + a soft contact shadow always visible under feet to eliminate "floating" sensation.
    private func setupGround(_ root: SCNNode) {
        guard groundEnabled || contactShadowOnly else {
            floorNode?.removeFromParentNode(); floorNode = nil
            contactShadow?.removeFromParentNode(); contactShadow = nil
            stageRig?.removeFromParentNode(); stageRig = nil
            return
        }
        // World Y of feet + horizontal range
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

        // A directional light's shadow map defaults to a 1-unit orthographic box. Anything outside
        // that box came out fully shadowed, which is what painted the huge dark triangle across the
        // ground. Size the box to the character instead, and keep it tight so the map stays sharp.
        if let sun = sunLight {
            let h = max(modelHeight, 0.1)
            sun.orthographicScale = CGFloat(h * 1.6)
            sun.zNear = 0.05
            sun.zFar = CGFloat(h * 12)
            sun.shadowRadius = 5
        }

        floorNode?.removeFromParentNode()

        if backgroundType == .sky {
            // A big finite plane rather than SCNFloor. SCNFloor's texture coordinates are its own
            // business - paving on it came out as one smeared slab - while a plane's UVs run 0...1
            // across its extent, so the repeat count is exactly what is asked for. The fog hides
            // the far edge, and there is no reflection to flatten the paving into a sheet of sky.
            let h = max(modelHeight, 0.1)
            let ground = SCNPlane(width: CGFloat(h * 60), height: CGFloat(h * 60))
            let gm = ground.firstMaterial!
            gm.diffuse.contents = Self.plazaTexture
            gm.diffuse.wrapS = .repeat
            gm.diffuse.wrapT = .repeat
            gm.diffuse.contentsTransform = SCNMatrix4MakeScale(110, 110, 1)   // ~0.55m slabs
            gm.lightingModel = .lambert
            gm.isDoubleSided = false
            let gnode = SCNNode(geometry: ground)
            gnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            gnode.simdPosition = simd_float3(0, minY, 0)
            scene.rootNode.addChildNode(gnode)
            floorNode = gnode
        } else {

        // Floor: Slightly brighter than background color + slight reflection, forming a clear "ground" reference
        let floor = SCNFloor()
        // Glossy near-black dance floor. Unlit on purpose: SCNFloor is infinite, so letting the
        // stage spots hit it turns the whole frame into a wash; the visible light is the additive
        // pool instead. The reflection is what sells the club stage, so it stays - gated by
        // DeviceTier, since a reflection re-renders the entire scene.
        floor.reflectivity = DeviceTier.floorReflectivity > 0 ? 0.35 : 0
        floor.reflectionFalloffEnd = CGFloat(max(modelHeight, 0.1) * 1.4)
        floor.firstMaterial?.diffuse.contents = UIColor(red: 0.030, green: 0.030, blue: 0.040, alpha: 1)
        floor.firstMaterial?.lightingModel = .constant
        floor.firstMaterial?.roughness.contents = 0.82
        let node = SCNNode(geometry: floor)
        node.simdPosition = simd_float3(0, minY, 0)
        scene.rootNode.addChildNode(node)
        floorNode = node
        }

        // Soft contact shadow under feet (always visible, provides "grounding" cues even if directional light shadows aren't rendered)
        contactShadow?.removeFromParentNode()
        // Sized from the character's height, not from the bounding box: with the arms out, the box
        // is wider than the character is tall and the "contact" shadow covered the whole foreground.
        let shadowScale: Float = backgroundType == .sky ? 1.15 : 1.0
        let blobW = min(footSpan * 2.4, max(modelHeight, 0.1) * 0.75) * shadowScale
        let blob = SCNPlane(width: CGFloat(blobW), height: CGFloat(blobW * 0.62))
        let bm = blob.firstMaterial!
        bm.diffuse.contents = backgroundType == .sky ? Self.contactShadowTextureStrong : Self.contactShadowTexture
        bm.transparency = backgroundType == .sky ? 1.0 : 0.85
        bm.lightingModel = .constant
        bm.isDoubleSided = true
        bm.writesToDepthBuffer = false
        let bnode = SCNNode(geometry: blob)
        bnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)          // Tiled on the ground
        bnode.simdPosition = simd_float3(cx, minY + 0.003, cz)
        bnode.renderingOrder = 1                                     // Drawn above the floor
        scene.rootNode.addChildNode(bnode)
        contactShadow = bnode

        setupStageRig(feetY: minY, center: simd_float3(cx, 0, cz))
    }

    /// Club-stage set, built procedurally: an LED back wall, a lighting truss with fixtures,
    /// the sweeping beams those fixtures throw, a follow spot and a glossy floor. Studio
    /// background only - the sky stage is meant to read as daylight.
    private func setupStageRig(feetY: Float, center: simd_float3) {
        stageRig?.removeFromParentNode(); stageRig = nil

        guard groundEnabled, backgroundType == .studio else {
            // Back to the plain lighting used by the sky stage, thumbnails and AR.
            ambientLight?.intensity = 430
            keyLight?.intensity = 700
            sunLight?.intensity = 760
            return
        }
        let h = max(modelHeight, 0.1)
        let rig = SCNNode()

        // The stage lamps carry the image; the generic rig only fills the shadows.
        ambientLight?.intensity = 200
        ambientLight?.color = UIColor(red: 0.80, green: 0.78, blue: 0.95, alpha: 1)
        keyLight?.intensity = 90
        sunLight?.intensity = 130

        // MARK: LED back wall
        // Wide enough that its edges stay out of frame, and tall enough that its lower edge
        // passes below the floor - otherwise the wall ends in a hard dark band across the shot.
        let wall = SCNPlane(width: CGFloat(h * 5.2), height: CGFloat(h * 3.4))
        let wm = SCNMaterial()
        wm.lightingModel = .constant                       // A screen emits; it is not lit
        wm.diffuse.contents = CharacterSceneView.studioBackdrop()
        wm.isDoubleSided = false
        wall.materials = [wm]
        let wallNode = SCNNode(geometry: wall)
        wallNode.simdPosition = simd_float3(center.x, feetY + h * 1.25, center.z - h * 2.0)
        rig.addChildNode(wallNode)

        // MARK: Truss
        let truss = SCNBox(width: CGFloat(h * 4.0), height: CGFloat(h * 0.07),
                           length: CGFloat(h * 0.07), chamferRadius: 0)
        let tm = SCNMaterial(); tm.lightingModel = .lambert
        tm.diffuse.contents = UIColor(white: 0.16, alpha: 1)
        truss.materials = [tm]
        let trussNode = SCNNode(geometry: truss)
        trussNode.simdPosition = simd_float3(center.x, feetY + h * 2.25, center.z - h * 0.6)
        rig.addChildNode(trussNode)

        // MARK: Beams, hanging off the fixtures on that truss
        let beams: [(x: Float, color: UIColor, period: Double)] = [
            (-1.35, UIColor(red: 1.00, green: 0.25, blue: 0.65, alpha: 1), 6.8),
            (-0.80, UIColor(red: 0.45, green: 0.35, blue: 1.00, alpha: 1), 5.3),
            (-0.28, UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1), 7.6),
            ( 0.28, UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1), 6.1),
            ( 0.80, UIColor(red: 0.45, green: 0.35, blue: 1.00, alpha: 1), 7.1),
            ( 1.35, UIColor(red: 1.00, green: 0.25, blue: 0.65, alpha: 1), 5.7),
        ]
        let len = h * 2.6
        for b in beams {
            let can = SCNCylinder(radius: CGFloat(h * 0.05), height: CGFloat(h * 0.09))
            let cm = SCNMaterial(); cm.lightingModel = .lambert
            cm.diffuse.contents = UIColor(white: 0.1, alpha: 1)
            can.materials = [cm]
            let canNode = SCNNode(geometry: can)
            canNode.simdPosition = simd_float3(center.x + b.x * h, feetY + h * 2.19, center.z - h * 0.6)
            rig.addChildNode(canNode)

            let pivot = SCNNode()
            pivot.simdPosition = simd_float3(center.x + b.x * h, feetY + h * 2.15, center.z - h * 0.6)
            pivot.eulerAngles = SCNVector3(0, 0, -b.x * 0.30)   // Leaning in on the performer

            // Crossed quads rather than a cone: a cone always shows a hard silhouette edge and
            // reads as geometry. No billboard constraint - it overrides the node's orientation
            // and would cancel the lean. Greyscale-on-black texture, additive, so black adds nothing.
            let beamNode = SCNNode()
            beamNode.simdPosition = simd_float3(0, -Float(len) / 2, 0)
            for turn in [Float(0), Float.pi / 2] {
                let quad = SCNPlane(width: CGFloat(h * 0.75), height: CGFloat(len))
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = Self.beamTexture
                m.multiply.contents = b.color
                m.blendMode = .add
                m.writesToDepthBuffer = false
                m.isDoubleSided = true
                quad.materials = [m]
                let card = SCNNode(geometry: quad)
                card.eulerAngles = SCNVector3(0, turn, 0)
                beamNode.addChildNode(card)
            }
            beamNode.opacity = 0.8
            pivot.addChildNode(beamNode)

            // Sweep and breathe, each fixture on its own period so they never move as one block.
            let out = SCNAction.rotateBy(x: 0.04, y: 0.18, z: CGFloat(b.x > 0 ? -0.15 : 0.15), duration: b.period)
            let back = SCNAction.rotateBy(x: -0.04, y: -0.18, z: CGFloat(b.x > 0 ? 0.15 : -0.15), duration: b.period)
            out.timingMode = .easeInEaseOut; back.timingMode = .easeInEaseOut
            pivot.runAction(.repeatForever(.sequence([out, back])))

            let dim = SCNAction.fadeOpacity(to: 0.5, duration: b.period * 0.37)
            let up = SCNAction.fadeOpacity(to: 0.95, duration: b.period * 0.51)
            dim.timingMode = .easeInEaseOut; up.timingMode = .easeInEaseOut
            beamNode.runAction(.repeatForever(.sequence([dim, up])))

            rig.addChildNode(pivot)
        }

        // MARK: Follow spot straight overhead
        let followLen = h * 2.2
        let follow = SCNNode()
        follow.simdPosition = simd_float3(center.x, feetY + h * 1.75 - Float(followLen) / 2 + h * 0.9, center.z)
        for turn in [Float(0), Float.pi / 2] {
            let quad = SCNPlane(width: CGFloat(h * 0.9), height: CGFloat(followLen))
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Self.beamTexture
            m.multiply.contents = UIColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1)
            m.blendMode = .add
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            quad.materials = [m]
            let card = SCNNode(geometry: quad)
            card.eulerAngles = SCNVector3(0, turn, 0)
            follow.addChildNode(card)
        }
        follow.opacity = 0.45
        let fdim = SCNAction.fadeOpacity(to: 0.32, duration: 2.6)
        let fup = SCNAction.fadeOpacity(to: 0.52, duration: 3.4)
        fdim.timingMode = .easeInEaseOut; fup.timingMode = .easeInEaseOut
        follow.runAction(.repeatForever(.sequence([fdim, fup])))
        rig.addChildNode(follow)

        // MARK: Lights that actually shade the performer
        func spot(_ x: Float, _ y: Float, _ z: Float, _ color: UIColor, _ intensity: CGFloat,
                  _ inner: CGFloat, _ outer: CGFloat, shadow: Bool = false) -> SCNNode {
            let n = SCNNode()
            let l = SCNLight()
            l.type = .spot
            l.color = color
            l.intensity = intensity
            l.spotInnerAngle = inner
            l.spotOuterAngle = outer
            l.attenuationStartDistance = CGFloat(h * 1.2)
            l.attenuationEndDistance = CGFloat(h * 4.4)     // Dies out before it can wash the floor
            l.castsShadow = shadow && DeviceTier.dynamicShadows
            l.shadowMode = .forward
            l.shadowColor = UIColor(white: 0, alpha: 0.45)
            l.shadowRadius = 8
            l.shadowSampleCount = DeviceTier.shadowSampleCount
            n.light = l
            n.simdPosition = simd_float3(center.x + x * h, feetY + y * h, center.z + z * h)
            n.look(at: SCNVector3(center.x, feetY + h * 0.65, center.z))
            return n
        }
        rig.addChildNode(spot(-0.9, 2.2, 0.9, UIColor(red: 1.0, green: 0.78, blue: 0.92, alpha: 1), 640, 20, 55, shadow: true))
        rig.addChildNode(spot( 0.9, 2.2, 0.9, UIColor(red: 0.76, green: 0.90, blue: 1.0, alpha: 1), 430, 20, 55))
        // Front fill: without it the face falls into shadow against a bright LED wall.
        rig.addChildNode(spot( 0.0, 1.35, 1.9, UIColor(red: 1.0, green: 0.98, blue: 0.96, alpha: 1), 470, 26, 62))

        // MARK: Pool of light on the floor
        let pool = SCNPlane(width: CGFloat(h * 2.4), height: CGFloat(h * 1.3))
        let pm = pool.firstMaterial!
        pm.diffuse.contents = Self.lightPoolTexture
        pm.lightingModel = .constant
        pm.blendMode = .add
        pm.writesToDepthBuffer = false
        pm.isDoubleSided = true
        let poolNode = SCNNode(geometry: pool)
        poolNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        poolNode.simdPosition = simd_float3(center.x, feetY + 0.002, center.z)
        rig.addChildNode(poolNode)

        scene.rootNode.addChildNode(rig)
        stageRig = rig
    }

    /// Beam texture: a shaft that widens and fades as it falls, soft at both sides. Painted as
    /// greyscale on black - under additive blending black adds nothing, so no alpha handling is
    /// involved and the beam can never darken what is behind it.
    private static let beamTexture: UIImage = {
        let side: CGFloat = 256
        let s = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            let rgb = CGColorSpaceCreateDeviceRGB()
            c.setFillColor(UIColor.black.cgColor)
            c.fill(CGRect(origin: .zero, size: s))
            for row in 0..<Int(side) {
                let t = CGFloat(row) / (side - 1)                 // 1 at the lamp, 0 at the far end
                let halfW = (0.42 - 0.34 * t) * side              // Narrow at the lamp, wide where it lands
                let level = pow(t, 1.25) * 0.9 + 0.03
                let cols = [UIColor.black.cgColor,
                            UIColor(red: level, green: level, blue: level, alpha: 1).cgColor,
                            UIColor.black.cgColor]
                let g = CGGradient(colorsSpace: rgb, colors: cols as CFArray, locations: [0, 0.5, 1])!
                c.saveGState()
                c.clip(to: CGRect(x: side / 2 - halfW, y: CGFloat(row), width: halfW * 2, height: 1))
                c.drawLinearGradient(g, start: CGPoint(x: side / 2 - halfW, y: 0),
                                     end: CGPoint(x: side / 2 + halfW, y: 0), options: [])
                c.restoreGState()
            }
        }
    }()

    /// Outdoor paving: light stone tiles with soft joints and a little block-to-block variation.
    /// The variation matters - perfectly uniform tiles still read as a printed board.
    private static let plazaTexture: UIImage = {
        let side: CGFloat = 256
        let s = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            // Joint colour fills the texture; the tiles are then drawn inset on top of it, which
            // gives joints of a real width. Thin hairline joints average away to flat grey at
            // this camera distance - which is exactly what made the ground read as a blank board.
            c.setFillColor(UIColor(red: 0.58, green: 0.61, blue: 0.65, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: s))
            let inset: CGFloat = 5
            let shades: [CGFloat] = [0.0, -0.075, 0.05, -0.035]
            for (i, d) in shades.enumerated() {
                let col = CGFloat(i % 2), row = CGFloat(i / 2)
                c.setFillColor(UIColor(red: 0.70 + d, green: 0.72 + d, blue: 0.75 + d, alpha: 1).cgColor)
                c.fill(CGRect(x: col * side / 2 + inset, y: row * side / 2 + inset,
                              width: side / 2 - inset * 2, height: side / 2 - inset * 2))
            }
        }
    }()

    /// Floor light pool: cool centre fading to black (additive, so black is invisible).
    private static let lightPoolTexture: UIImage = {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            ctx.cgContext.setFillColor(UIColor.black.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: s))
            let colors = [UIColor(red: 0.46, green: 0.36, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.16, green: 0.12, blue: 0.22, alpha: 1).cgColor,
                          UIColor.black.cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.5, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                             endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
    }()

    /// Soft circular contact shadow map: black center, transparent edges. Fixed content -> generated only once.
    private static let contactShadowTexture: UIImage = makeContactShadowImage(0.55)
    /// Outdoors the ground is bright and there is no pool of stage light, so the shadow has to
    /// carry the grounding on its own.
    private static let contactShadowTextureStrong: UIImage = makeContactShadowImage(0.8)

    private static func makeContactShadowImage(_ alpha: CGFloat) -> UIImage {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let colors = [UIColor(white: 0, alpha: alpha).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g,
                startCenter: CGPoint(x: s.width/2, y: s.height/2), startRadius: 0,
                endCenter: CGPoint(x: s.width/2, y: s.height/2), endRadius: s.width/2, options: [])
        }
    }

    /// Calculate the actual Up/Left/Forward axes using bone positions, forcing the root node to be Y-up and facing +Z.
    /// Do not rely on USD's upAxis metadata (that metadata is unreliable).
    /// Static portrait pose: Required only for VRM (VRoid). Arms lowered in an A-shape, with slight perturbations to the torso chain,
    /// forcing SceneKit to re-evaluate skinning — otherwise these skeletons collapse in T-pose (arms becoming planes, heads floating).
    /// Not called during dance paths (retargeter will drive bones itself).
    /// VRoid models are authored for MToon, a toon shader. The USDZ conversion turns that into
    /// physically based materials, and under stage lighting a pale anime face immediately clips to
    /// flat white - the eyes and brows disappear. Lambert with no specular keeps the authored
    /// colours, still responds to the coloured stage lights, and cannot blow out the same way.
    private func applyToonShading(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                m.lightingModel = .lambert
                m.specular.contents = UIColor.black
            }
        }
    }

    private func applyPortraitPose() {
        guard boneNodes["J_Bip_C_Hips"] != nil else { return }   // VRM only
        rotateBone(scheme.leftArm,  angle:  1.0, axis: simd_float3(0, 0, 1))
        rotateBone(scheme.rightArm, angle: -1.0, axis: simd_float3(0, 0, 1))
        rotateBone(scheme.spine,    angle: 0.03, axis: simd_float3(1, 0, 0))
        rotateBone(scheme.head,     angle: 0.03, axis: simd_float3(1, 0, 0))
    }

    private func rotateBone(_ name: String, angle: Float, axis: simd_float3) {
        guard let b = boneNodes[name] else { return }
        b.simdOrientation = simd_mul(b.simdOrientation, simd_quatf(angle: angle, axis: axis))
    }

    private func normalizeOrientation(_ root: SCNNode) {
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let lsh = boneNodes[scheme.leftShoulder]?.simdWorldPosition,
              let rsh = boneNodes[scheme.rightShoulder]?.simdWorldPosition else { return }
        let up = simd_normalize(head - hips)            // Character's "up"
        let right0 = simd_normalize(lsh - rsh)           // Character's left shoulder ->, as +X
        let forward = simd_normalize(simd_cross(right0, up))
        let right = simd_normalize(simd_cross(up, forward))
        // m: Identity basis -> Model basis; Inverse rotates model back to identity basis
        let m = simd_float3x3(right, up, forward)
        root.simdOrientation = simd_quatf(m).inverse
    }

    /// Set a fixed front fullscreen camera using bone positions (more reliable than bounding boxes, not affected by skeleton extensions).
    private func setupFrontCamera() {
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let foot = boneNodes[scheme.leftFoot]?.simdWorldPosition else { return }
        let height = abs(head.y - foot.y)
        guard height > 0 else { return }
        modelHeight = height
        let center = SCNVector3(hips.x, (head.y + foot.y) / 2, hips.z)
        print(String(format: "[Cam] head.y=%.2f foot.y=%.2f height=%.2f center=(%.2f,%.2f,%.2f)",
                     head.y, foot.y, height, center.x, center.y, center.z))

        // Reuse existing camera (avoid adding new camera nodes on each switch)
        let cam = cameraNode ?? {
            let n = SCNNode(); n.camera = SCNCamera()
            scene.rootNode.addChildNode(n); cameraNode = n; return n
        }()
        cam.camera?.zNear = Double(height) * 0.01
        cam.camera?.zFar = Double(height) * 50
        // Without HDR there is no tone mapping, so anything brighter than 1.0 clips to white -
        // pale skin and white clothing lose all their shading. Fixed exposure, not adaptive,
        // so the image does not breathe while the character dances.
        cam.camera?.wantsHDR = true
        cam.camera?.wantsExposureAdaptation = false
        cam.camera?.exposureOffset = -0.1
        if groundEnabled {
            // Large performance view: slightly top-down so the floor and shadow stay visible.
            // Aimed above the waist, which lifts the character clear of the controls at the bottom
            // of the screen and leaves the pool of light in shot below the feet.
            cam.camera?.fieldOfView = 55
            cam.position = SCNVector3(center.x, foot.y + height * 1.05, center.z + height * 2.25)
            cam.look(at: SCNVector3(center.x, foot.y + height * 0.48, center.z))
        } else {
            // Thumbnails/cards: Straight-on front view, centered full-body framing
            cam.camera?.fieldOfView = 62
            cam.position = SCNVector3(center.x, center.y, center.z + height * 1.9)
            cam.look(at: center)
        }
    }

    /// Traverse geometries of the entire subtree in world coordinates to find the Y-height of the AABB (meters).
    /// Handles arbitrary nested transforms and import scales, suitable for static models without skeletons.
    private func worldBoundingHeight(_ root: SCNNode) -> Float {
        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
        var any = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            let xs = [Float(a.x), Float(b.x)]
            let ys = [Float(a.y), Float(b.y)]
            let zs = [Float(a.z), Float(b.z)]
            for x in xs { for y in ys { for z in zs {
                let w = node.simdConvertPosition(simd_float3(x, y, z), to: nil)
                lo = simd_min(lo, w); hi = simd_max(hi, w); any = true
            }}}
        }
        return any ? (hi.y - lo.y) : 0
    }

    private func addLights() {
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .omni
        key.light?.intensity = 620
        key.position = SCNVector3(0, 100, 100)
        scene.rootNode.addChildNode(key)
        keyLight = key.light

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 380
        scene.rootNode.addChildNode(ambient)
        ambientLight = ambient.light

        // Directional light from the front-top, casting realistic soft shadows that change with movement.
        // forward soft shadows are expensive (one shadow pass per frame + multiple samples), disabled on low-end devices —
        // the contact shadow map under the feet provides enough "grounding" cues.
        let sun = SCNNode()
        let l = SCNLight(); l.type = .directional
        l.intensity = 700
        l.castsShadow = DeviceTier.dynamicShadows
        l.shadowMode = .forward            // Universally reliable (including the Simulator), and the shadow is visible on the floor
        l.shadowColor = UIColor(white: 0, alpha: 0.5)
        l.shadowRadius = 6
        l.shadowSampleCount = DeviceTier.shadowSampleCount
        sun.light = l
        sunLight = l
        sun.eulerAngles = SCNVector3(-Float.pi / 2.2, Float.pi / 12, 0)  // Closer to straight above -> shadows gather under feet
        scene.rootNode.addChildNode(sun)
    }
}

struct CharacterSceneView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var framed = false }

    func makeUIView(context: Context) -> SCNView {
        // When switching back from AR, reattach character to screen scene and re-sample retargeting
        controller.reattachToScreenScene()
        onAttach?()
        let view = SCNView()
        view.scene = controller.scene
        view.antialiasingMode = DeviceTier.antialiasing   // Lower anti-aliasing on low-end to reduce lag
        view.allowsCameraControl = true
        // Controlled turntable: Horizontal orbit around character + restricted pitch angle, avoiding ground halos in face at eye-level
        let cc = view.defaultCameraController
        cc.interactionMode = .orbitTurntable
        cc.inertiaEnabled = true
        cc.minimumVerticalAngle = -6      // Can't look up too much
        cc.maximumVerticalAngle = 55      // Can't look down to ground level to see ground VFX
        cc.target = SCNVector3(0, controller.feetY + controller.modelHeight * 0.5, 0)
        // Set background and ground based on background type
        controller.updateBackgroundAndGround()
        view.backgroundColor = .clear
        // Our own light rig lights the scene. autoenablesDefaultLighting would add another
        // full-strength omni on top of it, which is what blew the character out to flat white.
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true      // Continuous rendering to avoid frozen frames after switching
        view.isPlaying = true
        if let cam = controller.cameraNode { view.pointOfView = cam }
        holder?.scnView = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if let cam = controller.cameraNode { uiView.pointOfView = cam }
    }

    /// "Stage" background image with vertical gradient + bottom spotlight. Fixed content -> generated once and reused
    /// (previously a 300x650 CG image was redrawn every time updateBackgroundAndGround() was called).
    static let studioImage: UIImage = makeStudioBackdrop()
    static let skyImage: UIImage = makeSkyBackdrop()

    static func studioBackdrop() -> UIImage { studioImage }
    static func skyBackdrop() -> UIImage { skyImage }

    /// The LED back wall: colour bands behind a panel grid, knocked back and vignetted so it
    /// frames the performer instead of flooding the frame.
    private static func makeStudioBackdrop() -> UIImage {
        let size = CGSize(width: 512, height: 288)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let rgb = CGColorSpaceCreateDeviceRGB()
            c.setFillColor(UIColor.black.cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            let bands: [(CGFloat, UIColor)] = [
                (0.10, UIColor(red: 0.95, green: 0.15, blue: 0.55, alpha: 1)),
                (0.32, UIColor(red: 0.45, green: 0.20, blue: 0.95, alpha: 1)),
                (0.55, UIColor(red: 0.10, green: 0.65, blue: 0.98, alpha: 1)),
                (0.78, UIColor(red: 0.55, green: 0.25, blue: 0.95, alpha: 1)),
            ]
            for (y, color) in bands {
                let cols = [color.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0).cgColor]
                c.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: cols as CFArray, locations: [0, 1])!,
                                     startCenter: CGPoint(x: size.width * 0.5, y: size.height * y), startRadius: 0,
                                     endCenter: CGPoint(x: size.width * 0.5, y: size.height * y),
                                     endRadius: size.width * 0.55, options: [])
            }

            // Panel seams
            c.setStrokeColor(UIColor(white: 0, alpha: 0.30).cgColor)
            c.setLineWidth(1)
            for i in stride(from: 0, through: Int(size.width), by: 32) {
                c.move(to: CGPoint(x: CGFloat(i), y: 0)); c.addLine(to: CGPoint(x: CGFloat(i), y: size.height))
            }
            for j in stride(from: 0, through: Int(size.height), by: 32) {
                c.move(to: CGPoint(x: 0, y: CGFloat(j))); c.addLine(to: CGPoint(x: size.width, y: CGFloat(j)))
            }
            c.strokePath()

            // Sink the bottom into black so the wall meets the floor without a seam
            let fade = [UIColor.clear.cgColor, UIColor.black.cgColor]
            c.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: fade as CFArray, locations: [0, 0.55])!,
                                 start: CGPoint(x: 0, y: size.height * 0.45), end: .zero, options: [])

            // Vignette, then an overall knock-down: the wall must not out-shine the performer
            let vig = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
            c.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: vig as CFArray, locations: [0.35, 1])!,
                                 startCenter: CGPoint(x: size.width / 2, y: size.height * 0.55), startRadius: 0,
                                 endCenter: CGPoint(x: size.width / 2, y: size.height * 0.55),
                                 endRadius: size.width * 0.62, options: [])
            c.setFillColor(UIColor(white: 0, alpha: 0.45).cgColor)
            c.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Fallback procedural sky background
    private static func makeSkyBackdrop() -> UIImage {
        let size = CGSize(width: 400, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.45, green: 0.65, blue: 0.88, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor,
                          UIColor.white.cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.6, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }
}
