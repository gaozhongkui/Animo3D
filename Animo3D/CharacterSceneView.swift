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

    /// Only performs disk parsing, doesn't touch any on-screen scenes — can be called on background threads.
    /// Models are often 10~60MB; parsing + texture decoding + creating skinner takes hundreds of ms to seconds on iPhone X,
    /// and is the main reason for "lag when entering the stage page" if on the main thread.
    /// SceneKit's loader is not safe to run concurrently, and the dance grid asks for several
    /// parses of the *same* 11-60MB model at once: the selected card's LiveDanceView builds one,
    /// ThumbRenderer another, and the stage prewarm a third. Overlapping them produced scenes that
    /// came back empty - the card just never showed a character - so they are serialised here.
    /// Nothing is lost: they were already contending for the same disk read and GPU upload.
    private static let parseQueue = DispatchQueue(label: "com.animo3d.scene.parse")

    /// **Never call this on the main thread** - it parses tens of megabytes and now also waits
    /// behind any other parse in flight.
    static func loadSceneFile(at url: URL, warmUp: Bool = false) -> SCNScene? {
        parseQueue.sync {
            guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
                print("[Character] failed to load model at url: \(url.lastPathComponent)")
                return nil
            }
            if warmUp { Self.warmUp(loaded) }
            return loaded
        }
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
        // Reuse the same scene: remove the old character first, otherwise every switch stacks
        // another character and its textures in memory (this is what crashed the device after a
        // handful of switches).
        characterRoot?.removeFromParentNode()
        boneNodes.removeAll()
        isLoaded = false

        // Do not clone: cloning a skinned node breaks SCNSkinner's bone references (very visible on
        // iOS 16 - the mesh collapses into stretched triangles). Use the loaded root node directly.
        let root = loaded.rootNode
        scene.rootNode.addChildNode(root)
        characterRoot = root

        // Collect bone nodes and strip the baked animations the exporter left behind. This has to
        // walk the whole hierarchy: removeAllAnimations() only clears the node it is called on, and
        // the clips sit on the bones. Left in place they play themselves and fight the retargeter
        // for control of the skeleton.
        var found: [String] = []
        root.removeAllAnimations()
        root.enumerateChildNodes { node, _ in
            for key in node.animationKeys { node.removeAnimation(forKey: key) }
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
            }
        }

        // Bone naming scheme: VRoid (VRM) uses the J_Bip_ prefix, everything else is Mixamo.
        // PoseRetargeter, applyPortraitPose and normalizeOrientation all read this - leaving it at
        // its default silently breaks camera/video driving for every VRoid character.
        scheme = isVRM ? .vrm : .mixamo

        if isVRM { applyToonShading(root) }
        else { sanitizeMaterials(root) }

        if portraitMode { applyPortraitPose() }
        normalizeOrientation(root)
        setupFrontCamera()

        // Fallback height: when bone lookup fails (a Tripo static mesh has no Mixamo skeleton),
        // walk every geometry and convert the 8 corners of its local bounding box to world space.
        // root.boundingBox alone is unreliable - it may exclude children or ignore import scale.
        if modelHeight <= 0.01 { modelHeight = worldBoundingHeight(root) }

        if !lightsAdded { addLights(); lightsAdded = true }
        // Light levels depend on the model type *and* on whether the stage rig is up, so they are
        // applied at the end of updateBackgroundAndGround() - after setupStageRig has decided which
        // of the two rigs is on screen. Setting them here instead would be overwritten immediately.
        updateBackgroundAndGround()   // calls setupGround internally; do not call that separately
        captureBindPose()
        isLoaded = true
        return found.sorted()
    }

    // MARK: - Lighting levels

    /// Intensities for the four rig lights plus the image-based light.
    ///
    /// These used to be written from three different places - install(), setupStageRig() and
    /// addLights() - each with its own numbers, and the later writer silently won. On the studio
    /// stage that meant the per-model adjustment never took effect at all. Everything reads this
    /// one description now.
    private struct LightLevels {
        let key: CGFloat          // Front-left spot
        let fill: CGFloat         // Front-right omni
        let rim: CGFloat          // Back spot, draws the silhouette
        let sun: CGFloat          // Directional, casts the ground shadow
        let ibl: CGFloat          // lightingEnvironment.intensity, 0 disables it
        let shadowAlpha: CGFloat
        let stageSpot: CGFloat    // Scale on the three club-stage spots that light the performer
        let followSpot: CGFloat   // Overhead follow spot
        let rimShader: Float      // Strength of the additive fresnel rim in the fragment modifier
    }

    /// The cel-shaded VRM path clamps its own diffuse term, so it can take several times the light
    /// the physically based characters can: the same intensities clip skin and light clothing on a
    /// Mixamo model to flat white. The studio stage brings its own spots, an LED wall and a follow
    /// spot, so the generic rig only fills shadows there - all four lights drop, not just two.
    private var lightLevels: LightLevels {
        let onStudioStage = groundEnabled && backgroundType == .studio
        if isVRM {
            return onStudioStage
                ? LightLevels(key: 300, fill: 150, rim: 260, sun: 130, ibl: 0.35, shadowAlpha: 0.20,
                              stageSpot: 1.0, followSpot: 350, rimShader: 0.55)
                : LightLevels(key: 1200, fill: 600, rim: 800, sun: 450, ibl: 0.60, shadowAlpha: 0.20,
                              stageSpot: 1.0, followSpot: 350, rimShader: 0.55)
        }
        // Physically based characters take a fraction of the VRM levels. The numbers below were not
        // guessed: each source was rendered on its own offline and measured, and the stage rig
        // turned out to be upside down. The three club spots alone were producing a mean luma of
        // 0.42 and peaking at pure white - four times the key light - with the 90-degree back rim
        // also reaching 1.0 and wrapping right around the arms and face. The key, the light that is
        // supposed to shape the body, was the fifth-largest contributor.
        //
        // So the spots and the back rim are accents now and the key carries the image. The target
        // is the neutral rig the thumbnails are rendered with (mean 0.22, median 0.17): anything
        // above that and Erika's dark olive tunic starts rendering as pale grey, which is what made
        // every character look washed out and flat no matter how far the exposure was pulled down.
        return onStudioStage
            ? LightLevels(key: 170, fill: 10, rim: 16, sun: 30, ibl: 0.04, shadowAlpha: 0.45,
                          stageSpot: 0.07, followSpot: 25, rimShader: 0.04)
            : LightLevels(key: 380, fill: 150, rim: 300, sun: 180, ibl: 0.25, shadowAlpha: 0.45,
                          stageSpot: 0.07, followSpot: 25, rimShader: 0.04)
    }

    /// Push the current levels into the rig. Safe to call at any time; it only touches intensities.
    private func applyLightLevels() {
        let l = lightLevels
        characterRoot?.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.setValue(l.rimShader, forKey: "rimStrength") }
        }
        keyLight?.intensity = l.key
        fillLight?.intensity = l.fill
        rimLight?.intensity = l.rim
        sunLight?.intensity = l.sun
        sunLight?.shadowColor = UIColor(white: 0, alpha: l.shadowAlpha)
        scene.lightingEnvironment.contents = l.ibl > 0 ? CharacterSceneView.studioEnvironment : nil
        scene.lightingEnvironment.intensity = l.ibl
    }

    func updateBackgroundAndGround() {
        var fog: UIColor
        switch backgroundType {
        case .studio:
            // Not pure black: a very dark blue-grey keeps the falloff soft.
            fog = UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        case .sky:
            fog = UIColor(red: 0.82, green: 0.88, blue: 0.95, alpha: 1)
        }

        // Only the full stage paints a background. Thumbnails and the live dance cards draw over a
        // SwiftUI backdrop, so a scene background here covers that card with a flat slab of colour.
        if groundEnabled {
            switch backgroundType {
            case .studio:
                scene.background.contents = fog
            case .sky:
                scene.background.contents = UIImage(named: "sky_park") ?? CharacterSceneView.skyBackdrop()
            }
        } else {
            scene.background.contents = nil
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
        // Last, so the rig matches the stage that setupGround just built or tore down. Switching
        // background type goes through here too, which is why the levels follow the switch.
        applyLightLevels()
    }

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private var stageRig: SCNNode?              // Spotlight beams + floor light pool (studio stage only)

    /// Music energy for the stage rig, supplied by the player. Same source the particle VFX use.
    var levelProvider: (() -> Float)?
    private var beamBodies: [SCNNode] = []          // Pulsed with the music
    private var beamMaterials: [[SCNMaterial]] = [] // Per beam, recoloured on a beat
    private var poolBody: SCNNode?
    private var crowdGlow: [SCNNode] = []
    private var crowdRows: [(node: SCNNode, baseY: Float, phase: Float)] = []
    private var wallMaterial: SCNMaterial?
    private var beatEnv: Float = 0                  // Smoothed level, the baseline a beat rises above
    private var crowdPhase: Float = 0
    private var confetti: SCNParticleSystem?
    private var fireworks: [SCNParticleSystem] = []
    private var burstFrames = 0            // Frames left in the current burst
    private var chorusEnv: Float = 0       // Very slow envelope - a chorus is sustained, not a single hit
    private var chorusCooldown = 0
    private var stageHeight: Float = 1              // Character height, the unit the rig is built in
    private var beatCooldown = 0
    private var paletteShift = 0

    /// Beam colours, rotated by one position on every detected beat.
    private static let beamPalette: [UIColor] = [
        UIColor(red: 1.00, green: 0.25, blue: 0.65, alpha: 1),
        UIColor(red: 0.45, green: 0.35, blue: 1.00, alpha: 1),
        UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1),
        UIColor(red: 1.00, green: 0.72, blue: 0.30, alpha: 1),
        UIColor(red: 0.40, green: 1.00, blue: 0.75, alpha: 1),
    ]
    // All four rig lights are held here. Two of them used to be unreachable - `ambientLight` was
    // declared but never assigned (every write to it did nothing) and the fill/rim lights were
    // never stored - so setupStageRig could only dim half the rig and the rest kept blasting.
    private weak var keyLight: SCNLight?
    private weak var fillLight: SCNLight?
    private weak var rimLight: SCNLight?
    private weak var sunLight: SCNLight?
    private(set) var feetY: Float = 0   // World Y of feet (for VFX ground positioning)

    // --- 自动运镜变量 ---
    var isAutoOrbiting = false
    var orbitAngle: Float = 0

    func startAutoOrbit() { isAutoOrbiting = true }
    func stopAutoOrbit() { isAutoOrbiting = false }

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
        // pool instead. The reflection是 what sells the club stage, so it stays - gated by
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
        beamBodies.removeAll(); beamMaterials.removeAll(); crowdGlow.removeAll(); crowdRows.removeAll()
        confetti = nil; fireworks.removeAll(); burstFrames = 0
        poolBody = nil; wallMaterial = nil

        guard groundEnabled, backgroundType == .studio else { return }
        let h = max(modelHeight, 0.1)
        stageHeight = h
        let rig = SCNNode()

        // MARK: LED back wall
        // Wide enough that its edges stay out of frame, and tall enough that its lower edge
        // passes below the floor - otherwise the wall ends in a hard dark band across the shot.
        let wall = SCNPlane(width: CGFloat(h * 5.2), height: CGFloat(h * 3.4))
        let wm = SCNMaterial()
        wm.lightingModel = .constant                       // A screen emits; it is not lit
        wm.diffuse.contents = CharacterSceneView.ledContentTexture
        wm.diffuse.wrapS = .repeat
        wm.diffuse.wrapT = .repeat
        wm.isDoubleSided = false
        // The content scrolls by translating the texture matrix exactly one full repeat, which is
        // why the pattern has to tile seamlessly top-to-bottom - anything else flashes a seam once
        // per loop. Cheap: no geometry moves and no texture is re-uploaded.
        let tile = SCNMatrix4MakeScale(1, 1.6, 1)
        wm.diffuse.contentsTransform = tile
        let scroll = CABasicAnimation(keyPath: "contentsTransform")
        scroll.fromValue = tile
        scroll.toValue = SCNMatrix4Mult(tile, SCNMatrix4MakeTranslation(0, 1, 0))
        scroll.duration = 9
        scroll.repeatCount = .infinity
        wm.diffuse.addAnimation(scroll, forKey: "ledScroll")
        wall.materials = [wm]
        wallMaterial = wm
        let wallNode = SCNNode(geometry: wall)
        wallNode.simdPosition = simd_float3(center.x, feetY + h * 1.25, center.z - h * 2.0)
        rig.addChildNode(wallNode)

        // Framing sits on its own plane in front of the screen: the fade into the floor and the
        // vignette have to stay put. Baking them into the scrolling texture would send a black
        // band travelling up the wall.
        let mask = SCNPlane(width: CGFloat(h * 5.2), height: CGFloat(h * 3.4))
        let mm = SCNMaterial()
        mm.lightingModel = .constant
        mm.diffuse.contents = CharacterSceneView.ledMaskTexture
        mm.writesToDepthBuffer = false
        mm.isDoubleSided = false
        mask.materials = [mm]
        let maskNode = SCNNode(geometry: mask)
        maskNode.simdPosition = simd_float3(center.x, feetY + h * 1.25, center.z - h * 1.99)
        rig.addChildNode(maskNode)

        // MARK: Truss
        let truss = SCNBox(width: CGFloat(h * 4.0), height: CGFloat(h * 0.07),
                           length: CGFloat(h * 0.07), chamferRadius: 0)
        let tm = SCNMaterial(); tm.lightingModel = .lambert
        tm.diffuse.contents = UIColor(white: 0.16, alpha: 1)
        truss.materials = [tm]
        let trussNode = SCNNode(geometry: truss)
        trussNode.simdPosition = simd_float3(center.x, feetY + h * 2.25, center.z - h * 1.25)
        rig.addChildNode(trussNode)

        // MARK: Beams, hanging off the fixtures on that truss
        let beams: [(x: Float, color: UIColor, period: Double)] = [
            (-1.50, UIColor(red: 1.00, green: 0.25, blue: 0.65, alpha: 1), 6.8),
            (-0.95, UIColor(red: 0.45, green: 0.35, blue: 1.00, alpha: 1), 5.3),
            (-0.50, UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1), 7.6),
            ( 0.50, UIColor(red: 0.25, green: 0.80, blue: 1.00, alpha: 1), 6.1),
            ( 0.95, UIColor(red: 0.45, green: 0.35, blue: 1.00, alpha: 1), 7.1),
            ( 1.50, UIColor(red: 1.00, green: 0.25, blue: 0.65, alpha: 1), 5.7),
        ]
        let len = h * 2.6
        for b in beams {
            let can = SCNCylinder(radius: CGFloat(h * 0.05), height: CGFloat(h * 0.09))
            let cm = SCNMaterial(); cm.lightingModel = .lambert
            cm.diffuse.contents = UIColor(white: 0.1, alpha: 1)
            can.materials = [cm]
            let canNode = SCNNode(geometry: can)
            canNode.simdPosition = simd_float3(center.x + b.x * h, feetY + h * 2.19, center.z - h * 1.25)
            rig.addChildNode(canNode)

            let pivot = SCNNode()
            pivot.simdPosition = simd_float3(center.x + b.x * h, feetY + h * 2.15, center.z - h * 1.25)
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
            beamBodies.append(beamNode)
            beamMaterials.append(beamNode.childNodes.compactMap { $0.geometry?.firstMaterial })

            // Sweep and breathe, each fixture on its own period so they never move as one block.
            let out = SCNAction.rotateBy(x: 0.04, y: 0.18, z: CGFloat(b.x > 0 ? -0.15 : 0.15), duration: b.period)
            let back = SCNAction.rotateBy(x: -0.04, y: -0.18, z: CGFloat(b.x > 0 ? 0.15 : -0.15), duration: b.period)
            out.timingMode = .easeInEaseOut; back.timingMode = .easeInEaseOut
            pivot.runAction(.repeatForever(.sequence([out, back])))

            // No scripted fade here: brightness is driven by the music every frame instead, and a
            // running action would keep overwriting it.

            rig.addChildNode(pivot)
        }

        // MARK: Follow spot straight overhead
        let follow = SCNNode()
        let l = SCNLight()
        l.type = .spot
        l.spotInnerAngle = 15
        l.spotOuterAngle = 60
        l.color = UIColor(white: 1.0, alpha: 1.0)
        l.intensity = lightLevels.followSpot
        l.attenuationStartDistance = CGFloat(h * 1.5)
        l.attenuationEndDistance = CGFloat(h * 5.0)
        follow.light = l

        // No beam geometry on this one: a crossed-plane cone drew a visible seam straight down the
        // middle of the shot. It contributes light and the pool on the floor, nothing more.
        follow.simdPosition = simd_float3(center.x, feetY + h * 4.0, center.z)
        follow.look(at: SCNVector3(center.x, feetY, center.z))
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
        let k = lightLevels.stageSpot
        rig.addChildNode(spot(-0.9, 2.2, 0.9, UIColor(red: 1.0, green: 0.80, blue: 0.93, alpha: 1), 720 * k, 20, 55, shadow: true))
        rig.addChildNode(spot( 0.9, 2.2, 0.9, UIColor(red: 0.76, green: 0.90, blue: 1.0, alpha: 1), 430 * k, 20, 55))
        // Front fill: without it the face falls into shadow against a bright LED wall.
        rig.addChildNode(spot( 0.0, 1.35, 1.9, UIColor(red: 1.0, green: 0.98, blue: 0.96, alpha: 1), 540 * k, 26, 62))

        // The image-based light is set by applyLightLevels(), which runs after this.

        // MARK: Crowd
        // Silhouettes give the stage a depth cue nothing else provides: something sits in front of
        // the wall and behind the performer, so the space reads as a venue rather than a backdrop.
        // Three strips - one across the back, two angled in from the sides - each a flat card, so
        // the whole crowd costs six draw calls.
        func crowdRow(width: Float, at pos: simd_float3, yaw: Float) {
            let bodies = SCNPlane(width: CGFloat(width), height: CGFloat(width * 0.25))
            let bmat = SCNMaterial()
            bmat.lightingModel = .constant
            bmat.diffuse.contents = CharacterSceneView.crowdTextures.bodies
            bmat.isDoubleSided = true
            bmat.writesToDepthBuffer = false          // Never punch a hole in the wall behind them
            bodies.materials = [bmat]
            let bnode = SCNNode(geometry: bodies)
            bnode.simdPosition = pos
            bnode.eulerAngles = SCNVector3(0, yaw, 0)
            rig.addChildNode(bnode)

            // Glow sticks on their own additive card, a hair in front, so they can pulse alone.
            let glow = SCNPlane(width: CGFloat(width), height: CGFloat(width * 0.25))
            let gmat = SCNMaterial()
            gmat.lightingModel = .constant
            gmat.diffuse.contents = CharacterSceneView.crowdTextures.glow
            gmat.blendMode = .add
            gmat.isDoubleSided = true
            gmat.writesToDepthBuffer = false
            glow.materials = [gmat]
            let gnode = SCNNode(geometry: glow)
            gnode.simdPosition = pos + simd_float3(sin(yaw), 0, cos(yaw)) * (h * 0.02)
            gnode.eulerAngles = SCNVector3(0, yaw, 0)
            gnode.opacity = 0.7
            rig.addChildNode(gnode)
            crowdGlow.append(gnode)

            // Rows bob with the music, each on its own phase so the crowd never moves as one slab.
            let phase = Float(crowdRows.count) * 1.9
            crowdRows.append((bnode, pos.y, phase))
            crowdRows.append((gnode, gnode.simdPosition.y, phase))
        }

        crowdRow(width: h * 5.0, at: simd_float3(center.x, feetY + h * 0.52, center.z - h * 1.55), yaw: 0)
        crowdRow(width: h * 3.4, at: simd_float3(center.x - h * 2.0, feetY + h * 0.46, center.z - h * 0.2), yaw: 0.9)
        crowdRow(width: h * 3.4, at: simd_float3(center.x + h * 2.0, feetY + h * 0.46, center.z - h * 0.2), yaw: -0.9)

        // MARK: Chorus burst - confetti from the rig, fireworks off the wings
        // Both sit idle at birthRate 0 and are opened up for a few frames when a chorus is
        // detected. Creating the systems up front keeps the burst instant; building them on the
        // beat would drop frames exactly when the stage is busiest.
        let conf = SCNParticleSystem()
        conf.particleImage = CharacterSceneView.confettiTexture
        conf.birthRate = 0
        conf.particleLifeSpan = 4.5
        conf.particleLifeSpanVariation = 1.5
        conf.particleSize = CGFloat(h * 0.016)
        conf.particleSizeVariation = CGFloat(h * 0.007)
        conf.particleVelocity = CGFloat(h * 0.35)
        conf.particleVelocityVariation = CGFloat(h * 0.4)
        conf.spreadingAngle = 55
        conf.emittingDirection = SCNVector3(0, -1, 0)
        conf.acceleration = SCNVector3(0, -h * 0.65, 0)          // Flutter down, not plummet
        conf.particleAngularVelocity = 260
        conf.particleAngularVelocityVariation = 320
        conf.particleColorVariation = SCNVector4(0.9, 0.5, 0.4, 0)   // Wide hue spread
        conf.particleColor = UIColor(red: 1.0, green: 0.55, blue: 0.75, alpha: 1)
        conf.isLightingEnabled = false
        conf.emitterShape = SCNBox(width: CGFloat(h * 3.4), height: 0.01, length: CGFloat(h * 1.2), chamferRadius: 0)
        conf.birthLocation = .volume
        let confNode = SCNNode()
        confNode.simdPosition = simd_float3(center.x, feetY + h * 2.35, center.z - h * 0.2)
        confNode.addParticleSystem(conf)
        rig.addChildNode(confNode)
        confetti = conf

        for side in [Float(-1), Float(1)] {
            let fw = SCNParticleSystem()
            fw.particleImage = CharacterSceneView.sparkTexture
            fw.birthRate = 0
            fw.particleLifeSpan = 1.1
            fw.particleLifeSpanVariation = 0.5
            fw.particleSize = CGFloat(h * 0.045)
            fw.particleVelocity = CGFloat(h * 2.6)
            fw.particleVelocityVariation = CGFloat(h * 1.1)
            fw.spreadingAngle = 180                                // A sphere of sparks
            fw.acceleration = SCNVector3(0, -h * 1.1, 0)
            fw.blendMode = .additive
            fw.isLightingEnabled = false
            fw.stretchFactor = 0.02                                // Slight streak along the travel
            fw.particleColorVariation = SCNVector4(0.6, 0.4, 0.5, 0)
            fw.particleColor = UIColor(red: 1.0, green: 0.8, blue: 0.5, alpha: 1)
            let node = SCNNode()
            node.simdPosition = simd_float3(center.x + side * h * 1.9, feetY + h * 1.9, center.z - h * 0.9)
            node.addParticleSystem(fw)
            rig.addChildNode(node)
            fireworks.append(fw)
        }

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
        poolBody = poolNode

        scene.rootNode.addChildNode(rig)
        stageRig = rig
    }

    /// Beam texture: a shaft that widens and fades as it falls, soft at both sides. Painted as
    /// greyscale on black - under additive blending black adds nothing, so no alpha handling is
    /// involved and the beam can never darken what is behind it.
    /// Drives the stage rig from the music, once per rendered frame. SceneKit already calls its
    /// renderer delegate on every frame it draws, so there is no second display link to own or
    /// invalidate - it stops on its own when the view goes away.
    func driveStage() {
        guard !beamBodies.isEmpty, let level = levelProvider?() else { return }
        beatEnv = beatEnv * 0.82 + level * 0.18

        // Beams brighten with the music but never go fully dark, or the stage reads as broken.
        let glow = CGFloat(min(1.0, 0.42 + level * 1.15))
        for (i, body) in beamBodies.enumerated() {
            // Alternate fixtures sit slightly lower, so the row pulses as a wave, not a block.
            let bias: CGFloat = (i % 2 == 0) ? 0 : -0.12
            body.opacity = max(0.28, glow + bias)
        }

        if let pool = poolBody {
            let sc = 1.0 + level * 0.28
            pool.simdScale = simd_float3(sc, sc, 1)
            pool.opacity = CGFloat(0.45 + level * 0.55)
        }
        for g in crowdGlow { g.opacity = CGFloat(0.45 + level * 0.75) }
        // Crowd bob: driven by the smoothed level rather than the raw one, so they ride the track
        // instead of twitching on every transient.
        crowdPhase += 0.09 + beatEnv * 0.16
        for row in crowdRows {
            row.node.simdPosition.y = row.baseY + sin(crowdPhase + row.phase) * (0.012 + beatEnv * 0.05) * stageHeight
        }
        // The wall breathes with the track too, but gently - it has to stay behind the performer.
        wallMaterial?.multiply.contents = UIColor(white: CGFloat(0.85 + level * 0.30), alpha: 1)

        // A chorus is energy that stays up, so it is tested against a very slow envelope - a
        // single loud hit moves beatEnv but barely moves this one.
        chorusEnv = chorusEnv * 0.985 + level * 0.015
        if chorusCooldown > 0 { chorusCooldown -= 1 }
        if burstFrames > 0 {
            burstFrames -= 1
            if burstFrames == 0 {                       // Close the emitters again
                confetti?.birthRate = 0
                for fw in fireworks { fw.birthRate = 0 }
            }
        } else if chorusEnv > 0.20, level > 0.28, chorusCooldown == 0 {
            confetti?.birthRate = 900
            for fw in fireworks { fw.birthRate = 900 }
            burstFrames = 20                            // Roughly a third of a second of emission
            chorusCooldown = 60 * 12                    // At most one burst every ~12s
        }

        if beatCooldown > 0 { beatCooldown -= 1 }
        // A beat is a level that jumps clear of its own running average - the same test the
        // particle VFX use, so the lights and the particles hit together.
        if level > beatEnv * 1.28, level > 0.18, beatCooldown == 0 {
            beatCooldown = 14
            paletteShift += 1
            for (i, mats) in beamMaterials.enumerated() {
                let colour = Self.beamPalette[(i + paletteShift) % Self.beamPalette.count]
                for m in mats { m.multiply.contents = colour }
            }
        }
    }

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
    /// 电影级卡通着色器：让角色皮肤通透、光影平滑，且具有环境色彩感
    private func applyToonShading(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let g = node.geometry else { return }
            for m in g.materials {
                m.lightingModel = .lambert
                m.specular.contents = UIColor.black
                // 允许二次元角色接收微弱的环境光，使其不再“出戏”
                m.shaderModifiers = [
                    .lightingModel: Self.toonRampModifier,
                    .fragment: Self.rimLightModifier,
                ]
                m.setValue(lightLevels.rimShader, forKey: "rimStrength")
            }
        }
    }

    private static let toonRampModifier = """
    #pragma body
    // 计算光照强度
    float ndl = dot(normalize(_surface.normal), normalize(_light.direction));

    // 极其平滑的卡通阴影过渡
    float band = smoothstep(0.0, 0.6, ndl);

    // 大幅提升阴影区亮度 (Ambient Lift)，实现通透肤色
    // 从 0.65 提升至 0.78，阴影几乎不可见，只有淡淡的轮廓
    float ramp = mix(0.78, 1.0, band);

    _lightingContribution.diffuse = _light.intensity.rgb * ramp;
    """

    /// Additive fresnel rim that lifts the silhouette off a dark stage. Its strength is a uniform
    /// rather than a constant: the cel-shaded VRM path can carry a strong one, while on pale cloth
    /// under physically based shading the same value paints a white edge onto a surface that is
    /// already near clipping.
    private static let rimLightModifier = """
    #pragma arguments
    float rimStrength;
    #pragma body
    float3 n = normalize(_surface.normal);
    float3 v = normalize(_surface.view);
    float rim = pow(1.0 - saturate(dot(n, v)), 4.0);
    float3 rimColor = float3(0.7, 0.8, 1.0);
    _output.color.rgb += rim * rimColor * (rimStrength * _output.color.a);
    """

    /// Bring imported materials back to a predictable physically based setup.
    private func sanitizeMaterials(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .physicallyBased

                // Self-illumination is what blew Erika's face out to white: the exporter leaves it
                // on, and an emissive surface ignores every exposure control downstream.
                material.emission.contents = UIColor.black
                material.emission.intensity = 0
                material.selfIllumination.contents = UIColor.black
                material.selfIllumination.intensity = 0

                // Metalness in these models is junk left by the FBX -> SCN conversion: Erika's skin
                // comes in at 0.5 and one of her materials at a full 1.0, Peasant Girl is 0.5
                // throughout. Skin and cloth are dielectrics, and a metallic one mirrors the stage
                // environment instead of showing its own texture - which is why every character
                // used to react differently to the same lighting. Force it off.
                material.metalness.contents = NSNumber(value: 0)
                material.metalness.intensity = 1

                // Roughness, unlike metalness, is authored per material and worth keeping: eyes come
                // in at 0.03, clothes around 0.4, skin around 0.6, and that spread is what makes
                // leather look like leather next to cloth. Overriding it with one value for
                // everything flattened every character into the same matte clay. Only the mirror
                // end of the range is clamped away, since that is where the stage lamps punch a
                // white specular hole through a face.
                if let authored = material.roughness.contents as? NSNumber {
                    material.roughness.contents = NSNumber(value: max(authored.doubleValue, 0.45))
                }
                material.roughness.intensity = 1

                material.shaderModifiers = [
                    .fragment: Self.rimLightModifier
                ]
                material.setValue(lightLevels.rimShader, forKey: "rimStrength")
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

        if let camera = cam.camera {
            camera.zNear = Double(height) * 0.01
            camera.zFar = Double(height) * 50
            // SCNCamera does not conform to SCNShadable - it has no shaderModifiers - so a
            // hand-written ACES curve cannot be attached here at all. It does not need to be:
            // wantsHDR turns on SceneKit's own tone mapping, and whitePoint/vignetting/contrast
            // are the supported knobs for exactly the grade that curve was reaching for.
            camera.wantsHDR = true
            camera.wantsExposureAdaptation = false
            camera.exposureOffset = isVRM ? 0.2 : -0.4

            // whitePoint is the luminance that maps to pure white. Raising it above 1 pulls the
            // highlights back off the clip point, which is what stops light skin and white
            // clothing on the physically based characters from fusing into one flat patch. It acts
            // on the top of the range only, so the body keeps its midtones while the face - the
            // palest, most forward-facing surface, and the one that catches both the key and the
            // follow spot - stops flattening out.
            camera.whitePoint = isVRM ? 1.0 : 2.3
            camera.averageGray = 0.18
            camera.contrast = isVRM ? 0.0 : 0.30

            // The vignette the ACES modifier tried to draw by hand, done by the renderer.
            camera.vignettingIntensity = DeviceTier.isLowEnd ? 0 : 0.4
            camera.vignettingPower = DeviceTier.isLowEnd ? 0 : 1.2

            camera.bloomIntensity = DeviceTier.isLowEnd ? 0 : (isVRM ? 0.4 : 0.12)
            camera.bloomThreshold = isVRM ? 1.1 : 1.6
            camera.bloomBlurRadius = 15.0

            if !DeviceTier.isLowEnd {
                camera.screenSpaceAmbientOcclusionIntensity = groundEnabled ? 0.4 : 0.2
                camera.screenSpaceAmbientOcclusionRadius = 1.0
            }
        }
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

    /// Build the four-light rig. Intensities are deliberately not set here - applyLightLevels()
    /// owns them, because they depend on the model type and on which stage is up.
    private func addLights() {
        // 1. Key light
        let key = SCNNode()
        let kl = SCNLight(); kl.type = .spot
        kl.spotInnerAngle = 35; kl.spotOuterAngle = 75
        // Slightly warm, so skin reads as skin against the cold pink/blue stage lamps.
        kl.color = UIColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1.0)
        kl.attenuationStartDistance = 5; kl.attenuationEndDistance = 25
        key.light = kl
        key.position = SCNVector3(-3, 6, 6)
        key.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(key)
        keyLight = kl

        // 2. Fill light
        let fill = SCNNode()
        let fl = SCNLight(); fl.type = .omni
        fl.color = UIColor(red: 0.9, green: 0.95, blue: 1.0, alpha: 1.0)
        fill.light = fl
        fill.position = SCNVector3(5, 2, 4)
        scene.rootNode.addChildNode(fill)
        fillLight = fl

        // 3. Rim light: back light that draws the silhouette
        let rim = SCNNode()
        let rl = SCNLight(); rl.type = .spot
        rl.color = UIColor.white
        rl.spotInnerAngle = 45; rl.spotOuterAngle = 90
        rim.light = rl
        rim.position = SCNVector3(0, 5, -8)
        rim.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(rim)
        rimLight = rl

        // 4. Sun: the only shadow caster
        let sun = SCNNode()
        let l = SCNLight(); l.type = .directional
        l.castsShadow = DeviceTier.dynamicShadows
        l.shadowMode = .forward
        l.shadowRadius = 8
        l.shadowSampleCount = DeviceTier.shadowSampleCount
        sun.light = l
        sunLight = l
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 10, 0)
        scene.rootNode.addChildNode(sun)

        applyLightLevels()
    }
}

struct CharacterSceneView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil
    /// Called once the stage has rendered its first frame - see Coordinator.
    var onFirstFrame: (() -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var framed = false
        var onFirstFrame: (() -> Void)?
        private var firstFrameDelivered = false
        private let controller: CharacterSceneController

        init(controller: CharacterSceneController) { self.controller = controller }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            controller.driveStage()

            // --- 电影级自动运镜：在录制时缓慢旋转镜头 ---
            if controller.isAutoOrbiting, let cam = controller.cameraNode {
                controller.orbitAngle += 0.008 // 每帧微小旋转
                let radius: Float = controller.groundEnabled ? (controller.modelHeight * 2.25) : (controller.modelHeight * 1.9)
                let px = sin(controller.orbitAngle) * radius
                let pz = cos(controller.orbitAngle) * radius

                // 平滑更新摄像机位置，保持注视角色
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0
                cam.simdPosition.x = px
                cam.simdPosition.z = pz
                cam.look(at: SCNVector3(0, controller.feetY + controller.modelHeight * 0.48, 0))
                SCNTransaction.commit()
            }
        }

        /// Fires once, after SceneKit has actually put a frame on screen.
        ///
        /// Building this view is not free - the floor (with its scene-re-rendering reflection),
        /// the shadow map, the stage rig and the particles are all assembled synchronously in
        /// `makeUIView`, and the first frame still has to upload geometry and textures. A caller
        /// that drops its loading mask when *parsing* finishes leaves the user staring at an empty
        /// stage through all of that; this is the signal to drop it on.
        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard !firstFrameDelivered else { return }
            firstFrameDelivered = true
            let cb = onFirstFrame
            onFirstFrame = nil
            DispatchQueue.main.async { cb?() }
        }
    }

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
        context.coordinator.onFirstFrame = onFirstFrame
        view.delegate = context.coordinator          // Feeds the music-driven stage rig each frame
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
    static let skyImage: UIImage = makeSkyBackdrop()

    static func skyBackdrop() -> UIImage { skyImage }

    /// The LED back wall: colour bands behind a panel grid, knocked back and vignetted so it
    /// frames the performer instead of flooding the frame.
    /// LED content. Every row is drawn from a function whose period is exactly the texture
    /// height, so the top edge matches the bottom edge and the scroll loops invisibly.
    static let ledContentTexture: UIImage = {
        let size = CGSize(width: 512, height: 288)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // A closed loop of stops - ending where it starts is what makes the tile seamless.
            let stops: [(CGFloat, CGFloat, CGFloat)] = [
                (0.95, 0.15, 0.55),   // magenta
                (0.45, 0.20, 0.95),   // violet
                (0.10, 0.65, 0.98),   // cyan
                (0.45, 0.20, 0.95),   // violet again, closing the ring
            ]
            let rows = Int(size.height)
            for y in 0..<rows {
                let t = CGFloat(y) / CGFloat(rows)
                let p = t * CGFloat(stops.count)
                let i = Int(p) % stops.count
                let j = (i + 1) % stops.count
                let f = p - floor(p)
                let a = stops[i], b = stops[j]

                // 优化扫视光条：让它更宽、更暗，避免产生背景亮线
                let bar = pow(0.5 + 0.5 * sin(t * .pi * 2), 4) // 周期减半，强度衰减更快
                let level = 0.20 + 0.35 * bar // 整体亮度大幅下调
                c.setFillColor(UIColor(red: (a.0 + (b.0 - a.0) * f) * level,
                                       green: (a.1 + (b.1 - a.1) * f) * level,
                                       blue: (a.2 + (b.2 - a.2) * f) * level, alpha: 1).cgColor)
                c.fill(CGRect(x: 0, y: CGFloat(y), width: size.width, height: 1))
            }

            // Panel seams. 288 / 32 = 9 rows exactly, so the grid tiles along with the colour.
            c.setStrokeColor(UIColor(white: 0, alpha: 0.32).cgColor)
            c.setLineWidth(1)
            for i in stride(from: 0, through: Int(size.width), by: 32) {
                c.move(to: CGPoint(x: CGFloat(i), y: 0)); c.addLine(to: CGPoint(x: CGFloat(i), y: size.height))
            }
            for j in stride(from: 0, through: Int(size.height), by: 32) {
                c.move(to: CGPoint(x: 0, y: CGFloat(j))); c.addLine(to: CGPoint(x: size.width, y: CGFloat(j)))
            }
            c.strokePath()

            // Overall knock-down: the wall must never out-shine the performer
            c.setFillColor(UIColor(white: 0, alpha: 0.52).cgColor)
            c.fill(CGRect(origin: .zero, size: size))
        }
    }()

    /// One confetti flake: a small rounded rectangle, tinted per particle by colour variation.
    static let confettiTexture: UIImage = {
        let s = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            // Thin strip inside a transparent square: particles are always drawn square, so the
            // ribbon shape has to live in the texture.
            ctx.cgContext.addPath(UIBezierPath(roundedRect: CGRect(x: 23, y: 8, width: 18, height: 48),
                                               cornerRadius: 5).cgPath)
            ctx.cgContext.fillPath()
        }
    }()

    /// Firework spark: a soft dot, bright core fading out, for additive blending.
    static let sparkTexture: UIImage = {
        let s = CGSize(width: 64, height: 64)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cols = [UIColor.white.cgColor,
                        UIColor.white.withAlphaComponent(0.5).cgColor,
                        UIColor.white.withAlphaComponent(0).cgColor]
            ctx.cgContext.drawRadialGradient(
                CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray,
                           locations: [0, 0.35, 1])!,
                startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        }
    }()

    /// A crowd, generated once. Heads, shoulders and a few raised arms along a strip; the random
    /// numbers come from a fixed seed so the same crowd is drawn every launch (an unstable crowd
    /// would pop every time the stage is rebuilt). The glow sticks live in a separate texture -
    /// that layer is additive and pulses with the beat, while the bodies stay flat black.
    private static func makeCrowd() -> (bodies: UIImage, glow: UIImage) {
        let size = CGSize(width: 1024, height: 256)
        var seed: UInt64 = 0x5EED
        func rnd() -> CGFloat {                       // Small deterministic LCG
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 10000) / 10000
        }
        var arms: [(CGPoint, CGFloat)] = []           // Tip positions for the glow pass

        let bodies = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(white: 0.02, alpha: 1).cgColor)
            var x: CGFloat = 10
            while x < size.width + 40 {
                let scale = 0.8 + rnd() * 0.5
                let headR = 15 * scale
                let baseY = size.height - 6 - rnd() * 14      // Slight variation in how tall they stand
                let headY = baseY - 96 * scale
                c.fillEllipse(in: CGRect(x: x - headR, y: headY - headR, width: headR * 2, height: headR * 2))
                // Shoulders: a wide rounded body under the head
                let bw = headR * 3.1, bh = 110 * scale
                let body = UIBezierPath(roundedRect: CGRect(x: x - bw / 2, y: headY + headR * 0.4,
                                                            width: bw, height: bh),
                                        cornerRadius: bw * 0.42)
                c.addPath(body.cgPath); c.fillPath()
                // Roughly a third of them have an arm up
                if rnd() < 0.34 {
                    let side: CGFloat = rnd() < 0.5 ? -1 : 1
                    let tipX = x + side * headR * 1.5
                    let tipY = headY - 52 * scale - rnd() * 26
                    c.setLineWidth(7 * scale)
                    c.setStrokeColor(UIColor(white: 0.02, alpha: 1).cgColor)
                    c.setLineCap(.round)
                    c.move(to: CGPoint(x: x + side * headR * 0.9, y: headY + headR * 1.1))
                    c.addLine(to: CGPoint(x: tipX, y: tipY))
                    c.strokePath()
                    arms.append((CGPoint(x: tipX, y: tipY), scale))
                }
                x += 34 + rnd() * 22
            }
        }

        let glow = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let rgb = CGColorSpaceCreateDeviceRGB()
            for (p, scale) in arms {
                let r = 16 * scale
                let tint = UIColor(red: 0.55 + rnd() * 0.45, green: 0.45 + rnd() * 0.4, blue: 0.95, alpha: 1)
                let cols = [tint.cgColor, UIColor.black.cgColor]
                c.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: cols as CFArray, locations: [0, 1])!,
                                     startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
            }
        }
        return (bodies, glow)
    }

    static let crowdTextures: (bodies: UIImage, glow: UIImage) = makeCrowd()

    /// 专业摄影棚环境贴图：模拟多灯箱布光，提供高级的高光反射
    static let studioEnvironment: UIImage = {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // 1. 基础深色背景
            c.setFillColor(UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            // 2. 模拟顶部大灯箱
            let topGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [UIColor.white.withAlphaComponent(0.3).cgColor, UIColor.clear.cgColor] as CFArray,
                                    locations: [0, 1])!
            c.drawLinearGradient(topGrad, start: .zero, end: CGPoint(x: 0, y: size.height * 0.4), options: [])

            // 3. 模拟左右两侧的专业长条灯（Softbox）
            // 这能在写实模型（如盔甲、眼神）上产生非常漂亮的反射条
            c.setShadow(offset: .zero, blur: 20, color: UIColor.white.cgColor)
            c.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 20, height: 180)) // 左侧灯管
            c.fill(CGRect(x: 450, y: 40, width: 20, height: 180)) // 右侧灯管

            // 4. 底部微弱回光
            let bottomGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                       colors: [UIColor(red: 0.2, green: 0.15, blue: 0.3, alpha: 1).cgColor, UIColor.clear.cgColor] as CFArray,
                                       locations: [0, 1])!
            c.drawLinearGradient(bottomGrad, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.7), options: [])
        }
    }()

    /// Static framing laid over the screen: sinks the bottom into the floor and vignettes the
    /// edges. Black with a varying alpha, so the scrolling content shows through the middle.
    static let ledMaskTexture: UIImage = {
        let size = CGSize(width: 512, height: 288)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let rgb = CGColorSpaceCreateDeviceRGB()
            let vig = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.85).cgColor]
            c.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: vig as CFArray, locations: [0.30, 1])!,
                                 startCenter: CGPoint(x: size.width / 2, y: size.height * 0.55), startRadius: 0,
                                 endCenter: CGPoint(x: size.width / 2, y: size.height * 0.55),
                                 endRadius: size.width * 0.62, options: [])
            let fade = [UIColor.clear.cgColor, UIColor.black.cgColor]
            c.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: fade as CFArray, locations: [0, 0.55])!,
                                 start: CGPoint(x: 0, y: size.height * 0.45), end: .zero, options: [])
        }
    }()

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
