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

final class CharacterSceneController: ObservableObject, BoneRig {

    /// Which scene the performance happens in.
    ///
    /// Only `.sky` is reachable: the club-stage set was taken out of the product. Everything that
    /// builds it - the LED wall, the truss and its beams, the crowd, the follow spot, the floor
    /// pool, the confetti - is still in this file but now dormant behind `backgroundType`, because
    /// the visual direction moved more than once and a procedural set is expensive to rebuild from
    /// scratch. It should be deleted as its own change once the direction has settled.
    enum BackgroundType: String, CaseIterable {
        case studio, sky
    }

    let scene = SCNScene()
    private(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // Character unit height (for AR scaling)
    let scheme = BoneScheme.mixamo   // Named bones of the Mixamo rig, the only skeleton shipped
    var groundEnabled = false   // Ground + top-down view enabled only for large performance view; disabled for thumbnails/small cards
    var contactShadowOnly = false   // Detail page: Only add contact shadow under feet (to give grounding sense), no dark floor
    private var lightsAdded = false

    @Published var backgroundType: BackgroundType = .sky {
        didSet { updateBackgroundAndGround() }
    }

    // Skeletal pose at load time, used for resetting.
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
        arGroundY = nil
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

        sanitizeMaterials(root)
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

    /// The studio stage brings its own spots, an LED wall and a follow spot, so the generic rig
    /// only fills shadows there - all four lights drop, not just two.
    private var lightLevels: LightLevels {
        let onStudioStage = groundEnabled && backgroundType == .studio
        // The numbers below were not guessed: each source was rendered on its own
        // offline and measured, and the stage rig
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

    /// The camera's tone mapping. Split by background, because the two backgrounds are two
    /// different lighting conditions and one grade cannot serve both.
    ///
    /// The dark club stage needs `whitePoint` well above 1 to pull light skin and pale cloth back
    /// off the clip point. Applied to the daylight scene that same curve maps a luminance of 1.0 to
    /// about 0.43 - so the white cumulus in the sky dome came out the same grey as the sky behind
    /// them, and the clouds simply disappeared. It read as "the sky texture is wrong"; the texture
    /// was fine, the grade was crushing it.
    private struct CameraGrade {
        let exposureOffset: CGFloat
        let whitePoint: CGFloat
        let contrast: CGFloat
        let vignetting: CGFloat
        let bloom: CGFloat
        let bloomThreshold: CGFloat
    }

    private var cameraGrade: CameraGrade {
        if groundEnabled && backgroundType == .studio {
            return CameraGrade(exposureOffset: -0.4, whitePoint: 2.3, contrast: 0.30,
                               vignetting: 0.40, bloom: 0.12, bloomThreshold: 1.6)
        }
        // Daylight: neutral exposure, white stays white, only a touch of contrast and bloom.
        return CameraGrade(exposureOffset: 0.0, whitePoint: 1.0, contrast: 0.08,
                           vignetting: 0.22, bloom: 0.05, bloomThreshold: 1.1)
    }

    private func applyCameraGrade() {
        guard let camera = cameraNode?.camera else { return }
        let g = cameraGrade
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = g.exposureOffset
        camera.whitePoint = g.whitePoint
        camera.averageGray = 0.18
        camera.contrast = g.contrast
        camera.vignettingIntensity = DeviceTier.isLowEnd ? 0 : g.vignetting
        camera.vignettingPower = DeviceTier.isLowEnd ? 0 : 1.2
        camera.bloomIntensity = DeviceTier.isLowEnd ? 0 : g.bloom
        camera.bloomThreshold = g.bloomThreshold
        camera.bloomBlurRadius = 15.0
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
            let hz = CharacterSceneView.skyHorizon
            fog = UIColor(red: CGFloat(hz.0), green: CGFloat(hz.1), blue: CGFloat(hz.2), alpha: 1)
        }

        // Only the full stage paints a background. Thumbnails and the live dance cards draw over a
        // SwiftUI backdrop, so a scene background here covers that card with a flat slab of colour.
        if groundEnabled {
            switch backgroundType {
            case .studio:
                scene.background.contents = fog
            case .sky:
                // A proper 2:1 equirectangular dome, built from the source photograph by
                // tools/make_sky.py: its sky and treeline only, with the paving discarded. Setting
                // the photo itself here - 704x1503, portrait, plaza included - is what wrapped a
                // picture of the ground across the sky.
                scene.background.contents = UIImage(named: "sky_dome") ?? CharacterSceneView.skyBackdrop()
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
            // Sky mode fades over a much longer run than the studio. At `h * 9` everything past
            // the performer was already horizon-coloured, which left nowhere to put a distant
            // skyline - anything far enough away to read as distant was also erased. The plaza is
            // `h * 30` to its edge, so it still ends inside the fog and its far edge never shows.
            let far: Float = backgroundType == .sky ? 22.0 : 6.5
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
        // background type goes through here too, which is why the levels and the grade follow the
        // switch rather than staying on whatever the model was mounted with.
        applyLightLevels()
        applyCameraGrade()
    }

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private var footShadows: [SCNNode] = []
    private var stageRig: SCNNode?              // Spotlight beams + floor light pool (studio stage only)
    private var skylineNode: SCNNode?           // Distant buildings and trees (sky background only)
    private var inlayNode: SCNNode?             // Stone medallion under the performer (sky only)

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
    private weak var sunNode: SCNNode?
    private(set) var feetY: Float = 0   // World Y of feet (for VFX ground positioning)

    /// BoneRig: the plane the retargeter plants the feet against. Only meaningful once a ground
    /// has been built, which is also the only time planting matters.
    var groundY: Float? {
        guard isLoaded else { return nil }
        // AR wins when it is set: `feetY` is measured off the bounding box in *this* controller's
        // screen scene, and in AR the character is re-parented under a plane anchor at an entirely
        // different world height and scaled to 1.3m. Planting against the screen scene's floor from
        // over there is what leaves the character hanging above the detected plane.
        if let ar = arGroundY { return ar }
        return (groundEnabled || contactShadowOnly) ? feetY : nil
    }

    /// The world Y of the plane the character was placed on in AR, or nil on the screen stage.
    /// Set by `ARCharacterView` at placement and on every tap-to-move, cleared on the way back.
    var arGroundY: Float?
    /// Where the character actually stands. The camera move orbits this, not the world origin -
    /// `normalizeOrientation` squares the model up but does not centre it, so orbiting (0,·,0) put
    /// the camera on a circle around a point the performer was not standing on.
    private(set) var stageCenter = simd_float3(repeating: 0)

    /// Slow camera move. On during preview as well as recording, so what the user watches while
    /// choosing is what the recording will look like.
    ///
    /// It used to be an unbounded `angle += 0.008`, a full turn every 26 seconds - which carried the
    /// camera round to the performer's back, and on the club stage straight through the LED wall and
    /// the crowd. It is a bounded swing now: a slow arc either side of wherever the shot was framed,
    /// with the distance breathing on a longer period so it does not feel like a turntable.
    var isAutoOrbiting = true
    private var orbitClock: Float = 0
    /// Azimuth and radius of the framing `setupFrontCamera` chose, captured on the first frame so
    /// the move starts exactly where the shot already is and never snaps.
    private var orbitBaseAzimuth: Float?
    private var orbitBaseRadius: Float = 0

    /// How far either side of the original framing the camera swings, in radians (about 14 deg).
    private let orbitSwing: Float = 0.25

    func startAutoOrbit() { isAutoOrbiting = true }
    func stopAutoOrbit() { isAutoOrbiting = false }
    func resetCameraMove() { orbitBaseAzimuth = nil; orbitClock = 0 }

    /// Advance the camera move by one frame. Called from the renderer delegate.
    func stepCameraMove() {
        guard isAutoOrbiting, let cam = cameraNode, modelHeight > 0 else { return }

        let dx = cam.simdPosition.x - stageCenter.x
        let dz = cam.simdPosition.z - stageCenter.z
        if orbitBaseAzimuth == nil {
            let r = sqrt(dx * dx + dz * dz)
            guard r > 1e-4 else { return }
            orbitBaseAzimuth = atan2(dx, dz)
            orbitBaseRadius = r
        }
        guard let base = orbitBaseAzimuth else { return }

        orbitClock += 1.0 / 30.0                     // the display link runs at 30
        let azimuth = base + sin(orbitClock * 0.20) * orbitSwing
        // Distance breathes on a longer period than the swing, so the two never line up into an
        // obvious loop.
        let radius = orbitBaseRadius * (1 + sin(orbitClock * 0.13) * 0.05)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        cam.simdPosition.x = stageCenter.x + sin(azimuth) * radius
        cam.simdPosition.z = stageCenter.z + cos(azimuth) * radius
        cam.look(at: SCNVector3(stageCenter.x,
                                feetY + modelHeight * 0.48,
                                stageCenter.z))
        SCNTransaction.commit()
    }

    /// A ring of distant skyline standing on the plaza.
    ///
    /// Sky mode had nothing between the sky and the ground. The dome carries a treeline, but it is
    /// painted at infinity and never moves, so as the camera swings the scene read as a figure on an
    /// empty grey plain under a photograph. Geometry a couple of dozen metres out parallaxes against
    /// the dome, and that parallax is what actually says "there is a world here".
    ///
    /// Built by hand rather than from `SCNCylinder`: a cylinder has caps, and a one-element
    /// `materials` array is reused across all three, so the skyline texture was painted over the top
    /// cap too - a translucent lid drawn straight across the sky. A ring of quads has no caps to
    /// get wrong, and its UVs are written here, so the repeat count is exact instead of being
    /// negotiated with a primitive's own texture mapping.
    ///
    /// Distance is set against the fog, which is the only thing making anything here look far away:
    /// sky mode fades from `h * 3` to `h * 22`, so at `h * 13` the ring comes out a little under
    /// half washed toward the horizon colour. Past `h * 22` it would be erased outright; much closer
    /// and no amount of haze stops it reading as a wall at the edge of the plaza.
    private func addSkyline(feetY: Float, height h: Float) {
        skylineNode?.removeFromParentNode()

        let radius = h * 13
        let band = h * 3.2
        let repeats: Float = 4          // how many times the strip goes round
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
            uvs.append(CGPoint(x: CGFloat(t * repeats), y: 0))    // v = 0 is the top of the strip
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
        m.lightingModel = .constant     // it is a silhouette; lighting it would defeat that
        m.diffuse.contents = CharacterSceneView.skylineTexture
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .clamp
        m.isDoubleSided = true          // the camera is inside the ring, so winding is moot
        m.writesToDepthBuffer = false   // nothing should ever be clipped by the horizon
        m.blendMode = .alpha
        geo.materials = [m]

        let node = SCNNode(geometry: geo)
        node.simdPosition = simd_float3(stageCenter.x, feetY, stageCenter.z)
        node.castsShadow = false
        node.renderingOrder = -20
        scene.rootNode.addChildNode(node)
        skylineNode = node
    }

    /// Ground: Visible floor (with slight reflection) + a soft contact shadow always visible under feet to eliminate "floating" sensation.
    private func setupGround(_ root: SCNNode) {
        guard groundEnabled || contactShadowOnly else {
            floorNode?.removeFromParentNode(); floorNode = nil
            contactShadow?.removeFromParentNode(); contactShadow = nil
            footShadows.forEach { $0.removeFromParentNode() }; footShadows = []
            stageRig?.removeFromParentNode(); stageRig = nil
            skylineNode?.removeFromParentNode(); skylineNode = nil
            inlayNode?.removeFromParentNode(); inlayNode = nil
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
            // Tighter than it was. A directional shadow map this small over a box this size has
            // plenty of texels for a body; blurring it by 5 threw away the one edge that reads as
            // contact - where the shadow meets the sole.
            sun.shadowRadius = 2.5
            // And the box has to travel. It is centred on the light's node, which sat at the world
            // origin, while the performer walks over a metre away on some takes - far enough to
            // leave the box, at which point the cast shadow simply stops existing and the floor
            // goes clean under a dancing character.
            if let node = sunNode { followPerformer(node, height: h) }
        }

        floorNode?.removeFromParentNode()
        inlayNode?.removeFromParentNode(); inlayNode = nil

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
            // 55 repeats of a 4x4 block: the same ~0.45m slab as before, now with sixteen of
            // them per tile instead of four.
            gm.diffuse.contentsTransform = SCNMatrix4MakeScale(55, 55, 1)
            // Anisotropic filtering, which a ground plane cannot do without. Seen almost edge-on,
            // isotropic mips have to blur along the short axis as hard as along the long one, so
            // the mid-distance turned to grey mush while the near slabs shimmered as the camera
            // moved. This is the single cheapest thing that made the paving look like paving.
            gm.diffuse.mipFilter = .linear
            gm.diffuse.maxAnisotropy = 8
            gm.lightingModel = .lambert
            gm.isDoubleSided = false

            let gnode = SCNNode(geometry: ground)
            gnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            gnode.simdPosition = simd_float3(0, minY, 0)
            scene.rootNode.addChildNode(gnode)
            floorNode = gnode

            // The medallion, centred on the performer rather than on the origin. Its own node so it
            // is torn down with the floor and rebuilt at the right place when the character changes.
            let inlay = SCNPlane(width: CGFloat(h * 5), height: CGFloat(h * 5))
            let im = inlay.firstMaterial!
            im.diffuse.contents = Self.plazaInlayTexture
            im.lightingModel = .lambert          // lit with the paving, so it takes the same sun
            im.isDoubleSided = false
            im.writesToDepthBuffer = false       // it is a decal on a plane 2mm below it
            let inode = SCNNode(geometry: inlay)
            inode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            inode.simdPosition = simd_float3(cx, minY + 0.002, cz)
            inode.renderingOrder = 1             // after the paving, before the contact shadow
            inode.castsShadow = false
            // Parented to the root, not to the floor: the floor node is rotated flat, so a child
            // of it would be rotated twice and positioned in that rotated frame.
            scene.rootNode.addChildNode(inode)
            inlayNode = inode
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

        // Soft contact shadow under feet.
        //
        // Only where there is no floor to cast onto - the detail pages, which is the case this was
        // written for. On the stage it is off: a painted ellipse under a character standing on a
        // lit, textured floor reads as a decal that follows them around, not as contact, and
        // judged side by side the stage looked better with nothing there at all. The real
        // grounding on the stage is the directional light's own shadow plus the feet actually
        // being on the plane (instrumented: the lowest sole holds within 0.04m of it).
        contactShadow?.removeFromParentNode(); contactShadow = nil
        footShadows.forEach { $0.removeFromParentNode() }; footShadows = []
        if !groundEnabled {
            // Sized from the character's height, not from the bounding box: with the arms out, the box
            // is wider than the character is tall and the "contact" shadow covered the whole foreground.
            let shadowScale: Float = backgroundType == .sky ? 1.15 : 1.0
            let blobW = min(footSpan * 2.4, max(modelHeight, 0.1) * 0.75) * shadowScale
            let blob = SCNPlane(width: CGFloat(blobW), height: CGFloat(blobW * 0.62))
            let bm = blob.firstMaterial!
            bm.diffuse.contents = backgroundType == .sky ? Self.contactShadowTextureStrong : Self.contactShadowTexture
            // The body pool the per-foot ones sit inside; at full strength the two doubled up
            // into a single dark smear.
            bm.transparency = backgroundType == .sky ? 0.8 : 0.65
            bm.lightingModel = .constant
            bm.isDoubleSided = true
            bm.writesToDepthBuffer = false
            let bnode = SCNNode(geometry: blob)
            bnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)          // Tiled on the ground
            bnode.simdPosition = simd_float3(cx, minY + 0.003, cz)
            bnode.renderingOrder = 2                                     // Above the floor and the inlay
            scene.rootNode.addChildNode(bnode)
            contactShadow = bnode
            followFeet(bnode, groundY: minY + 0.003)
            addFootContact(groundY: minY + 0.0045, span: footSpan)
        }

        stageCenter = simd_float3(cx, 0, cz)
        // After stageCenter: the ring is centred on where the performer stands, not on the origin,
        // and the camera move orbits the same point - so the two stay concentric and the skyline
        // does not drift across the frame as the shot swings.
        if backgroundType == .sky {
            addSkyline(feetY: minY, height: max(modelHeight, 0.1))
        } else {
            skylineNode?.removeFromParentNode(); skylineNode = nil
        }
        setupStageRig(feetY: minY, center: stageCenter)
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
                let quad = SCNPlane(width: CGFloat(h * 0.95), height: CGFloat(len))
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
            // Additive and unlit, like the wall: opacity here changes how much light the beam
            // appears to carry, not how exposed the performer is.
            beamNode.opacity = 0.95
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

    /// Outdoor paving, one tile of a 4x4 block of slabs.
    ///
    /// Three things are doing the work, and the ground looked like graph paper without any of them:
    ///
    /// - **A 4x4 block, with a per-slab shade drawn from a counter rather than a repeating list.**
    ///   The old texture was 2x2 with four hand-picked shades, so the same little checker repeated
    ///   110 times across the plaza and the eye picked the period straight out of the frame.
    /// - **A chamfer on every slab** - a lighter edge along the top and left, darker along the
    ///   bottom and right. That is the only cue that a slab is a block of stone with a thickness
    ///   rather than a rectangle of paint, and it costs two strokes per slab.
    /// - **Grain.** Flat fills stay flat under the fog no matter what colour they are.
    ///
    /// Joints are drawn by filling the whole texture with the joint colour and insetting the slabs
    /// on top, which gives them a real width. The inset is per-slab, so the joint at the texture
    /// border is half from each side and tiles seamlessly.
    private static let plazaTexture: UIImage = {
        let side: CGFloat = 512
        let n = 4                                     // slabs per axis
        let cell = side / CGFloat(n)
        let s = CGSize(width: side, height: side)

        var seed: UInt64 = 0x9E3779B9
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }

        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            // Joint: a shade darker and a touch warmer than the slabs, so the grid reads as a
            // shadowed gap rather than as a drawn line.
            c.setFillColor(UIColor(red: 0.545, green: 0.560, blue: 0.585, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: s))

            let inset: CGFloat = 5
            for row in 0..<n {
                for col in 0..<n {
                    let d = (rnd() - 0.5) * 0.14      // per-slab shade
                    let r = CGRect(x: CGFloat(col) * cell + inset, y: CGFloat(row) * cell + inset,
                                   width: cell - inset * 2, height: cell - inset * 2)
                    c.setFillColor(UIColor(red: 0.705 + d, green: 0.720 + d,
                                           blue: 0.740 + d, alpha: 1).cgColor)
                    c.fill(r)

                    // Chamfer. Light where the sky falls on the bevel, dark on the far side.
                    c.setLineWidth(3)
                    c.setStrokeColor(UIColor(white: 1, alpha: 0.20).cgColor)
                    c.beginPath()
                    c.move(to: CGPoint(x: r.minX, y: r.maxY))
                    c.addLine(to: CGPoint(x: r.minX, y: r.minY))
                    c.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                    c.strokePath()
                    c.setStrokeColor(UIColor(white: 0, alpha: 0.13).cgColor)
                    c.beginPath()
                    c.move(to: CGPoint(x: r.maxX, y: r.minY))
                    c.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                    c.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                    c.strokePath()
                }
            }

            // Grain over everything, joints included: stone is not a flat fill, and mip levels
            // average this into a slight tonal noise that keeps the mid-distance from going
            // completely dead.
            for _ in 0..<9000 {
                let x = rnd() * side, y = rnd() * side
                let w = 1 + rnd() * 1.6
                c.setFillColor(UIColor(white: rnd() < 0.5 ? 0 : 1, alpha: 0.045 + rnd() * 0.05).cgColor)
                c.fill(CGRect(x: x, y: y, width: w, height: w))
            }
        }
    }()

    /// The inlay the performer stands on: a shallow stone medallion set into the paving.
    ///
    /// This is the difference between a stage and a car park. The plaza is 30 body-heights to its
    /// edge in every direction and identical all the way out, so there was nothing in the lower two
    /// thirds of the frame saying where the subject was - the camera swing read as drifting over
    /// paving rather than as circling a stage. A disc centred on the performer gives the shot a
    /// centre, and its rim gives the swing something to move against.
    ///
    /// Stone-toned rather than lit: sky mode is daylight, and a glowing ring here would look like a
    /// prop from the club stage that got left outdoors.
    private static let plazaInlayTexture: UIImage = {
        let side: CGFloat = 512
        let s = CGSize(width: side, height: side)
        let mid = CGPoint(x: side / 2, y: side / 2)
        let rgb = CGColorSpaceCreateDeviceRGB()

        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            c.clear(CGRect(origin: .zero, size: s))

            /// `v` is a multiple of the paving's own colour and `a` is alpha, because the inlay is
            /// composited over the paving: the grain and joints underneath stay faintly visible, so
            /// it reads as stone cut into the plaza rather than as a disc laid on top of it.
            ///
            /// The whole range is within +/- 15% of the paving. A first pass went much darker and
            /// the medallion read as a pit the performer was standing in - it covers most of the
            /// lower frame, so anything with real contrast becomes the subject of the shot.
            func stone(_ v: CGFloat, _ a: CGFloat) -> CGColor {
                UIColor(red: 0.705 * v, green: 0.720 * v, blue: 0.740 * v, alpha: a).cgColor
            }

            // A shade cooler under the performer, opening to a brighter band at the rim - the way a
            // polished inlay catches the sky around its edge. Alpha falls to nothing over the last
            // few percent of the radius; a hard edge against the paving reads as a decal.
            let body = CGGradient(colorsSpace: rgb,
                                  colors: [stone(0.86, 0.45), stone(0.95, 0.45),
                                           stone(1.10, 0.55), stone(1.10, 0)] as CFArray,
                                  locations: [0, 0.55, 0.955, 1])!
            c.drawRadialGradient(body, startCenter: mid, startRadius: 0,
                                 endCenter: mid, endRadius: side / 2, options: [])

            // Two cut rings. Thin, and paler than the stone either side, which is what a chamfered
            // groove in bright daylight actually looks like.
            for (rf, lw, alpha) in [(0.955 as CGFloat, 5 as CGFloat, 0.50 as CGFloat),
                                    (0.62, 3, 0.34)] {
                c.setLineWidth(lw)
                c.setStrokeColor(UIColor(white: 1, alpha: alpha).cgColor)
                c.strokeEllipse(in: CGRect(x: mid.x - side / 2 * rf, y: mid.y - side / 2 * rf,
                                           width: side * rf, height: side * rf))
                c.setLineWidth(lw * 0.7)
                c.setStrokeColor(UIColor(white: 0, alpha: alpha * 0.30).cgColor)
                c.strokeEllipse(in: CGRect(x: mid.x - side / 2 * rf + lw, y: mid.y - side / 2 * rf + lw,
                                           width: side * rf - lw * 2, height: side * rf - lw * 2))
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

    /// Additive fresnel rim that lifts the silhouette off a dark stage. Its strength is a uniform
    /// rather than a constant: on pale cloth a high value paints a white edge onto a surface that
    /// is already near clipping, so the stage rig carries far less of it than the non-stage one.
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

    /// Calculate the actual Up/Left/Forward axes using bone positions, forcing the root node to be
    /// Y-up and facing +Z. Do not rely on USD's upAxis metadata (that metadata is unreliable).
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
            // The grade itself lives in `cameraGrade` and is pushed by applyCameraGrade(), which
            // runs from updateBackgroundAndGround(): it depends on which background is up, and this
            // function only runs when a model is mounted.
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

    /// Park the shadow-casting light above the performer, wherever they have danced to.
    ///
    /// A directional light's orthographic shadow box is centred on its node, and this one sat at
    /// the world origin. `orthographicScale` is sized to the character, so a take that travels -
    /// measured, over a metre on Belly Dance - walks the performer out of their own shadow box and
    /// the cast shadow disappears. Position only, through `positionConstraint`: the euler angles
    /// are the light's direction and must survive untouched.
    private func followPerformer(_ node: SCNNode, height: Float) {
        let hips = boneNodes[BoneScheme.mixamo.hips]
        node.constraints = [SCNTransformConstraint.positionConstraint(inWorldSpace: true) { [weak hips] _, pos in
            guard let hips else { return pos }
            let p = hips.simdWorldPosition
            return SCNVector3(p.x, p.y + height * 2, p.z)
        }]
    }

    /// One small dark pool under each foot, following it and fading as it leaves the ground.
    ///
    /// This is the part that makes the contact read as real. A single body-sized ellipse cannot:
    /// it says "something is above this patch of floor", never "this foot is on it". When one foot
    /// lifts and the other stays planted, only a per-foot pool shows the difference - the planted
    /// one stays dark and tight, the lifted one lightens and spreads, which is what an occlusion
    /// shadow actually does as the surfaces separate.
    ///
    /// Kept cheap on purpose: two unlit alpha planes, no depth writes, no extra shadow pass. The
    /// directional light's own shadow is still doing the long cast; these only fill the millimetres
    /// underneath the sole, which is exactly where a shadow map at this range has no resolution.
    private func addFootContact(groundY: Float, span: Float) {
        let scheme = BoneScheme.mixamo
        let feet = [scheme.leftFoot, scheme.rightFoot].compactMap { boneNodes[$0] }
        guard feet.count == 2 else { return }

        // A foot, not a body: sized off the stance width rather than the arms-out bounding box.
        let w = max(0.10, min(span * 0.55, max(modelHeight, 0.1) * 0.17))
        for foot in feet {
            let plane = SCNPlane(width: CGFloat(w), height: CGFloat(w * 0.78))
            let m = plane.firstMaterial!
            m.diffuse.contents = Self.contactShadowTextureStrong
            m.lightingModel = .constant
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            let node = SCNNode(geometry: plane)
            node.renderingOrder = 3                  // above the body pool, still under everything else
            node.castsShadow = false
            node.simdPosition = simd_float3(foot.simdWorldPosition.x, groundY, foot.simdWorldPosition.z)
            scene.rootNode.addChildNode(node)

            // The ankle's world height while the sole is on the floor. The foot's height above the
            // ground is then simply how far the ankle has risen from here - measure it against the
            // ankle's *own* standing height instead and the number is a ratio of about 0.1m, which
            // saturates on the first bent knee: instrumented, that version read lift 0.9 to 3.4 on
            // a planted foot and held both pools at opacity 0 for the whole dance.
            let restAnkleY = foot.simdWorldPosition.y
            // Fade over a tenth of the character: below that the foot is rolling, not leaving.
            let fade = max(0.05, modelHeight * 0.10)
            node.constraints = [SCNTransformConstraint(inWorldSpace: true) { [weak foot, weak node] _, mtx in
                guard let foot, let node else { return mtx }
                let p = foot.simdWorldPosition
                let t = min(1, max(0, p.y - restAnkleY) / fade)
                // Opacity is set here rather than through some per-frame tick of its own: it is not
                // part of the transform, so writing it inside the constraint cannot feed back into
                // the evaluation, and there is no other hook that runs in lockstep with the pose.
                // It never reaches zero - a foot at knee height still occludes a little sky.
                node.opacity = CGFloat(0.95 - 0.78 * t)
                let k = 1 + t * 0.55                 // spreads as it separates, like the real thing
                var m = SCNMatrix4MakeScale(k, k, k)
                m = SCNMatrix4Mult(m, SCNMatrix4MakeRotation(-Float.pi / 2, 1, 0, 0))
                return SCNMatrix4Mult(m, SCNMatrix4MakeTranslation(p.x, groundY, p.z))
            }]
            footShadows.append(node)
        }
    }

    /// Keep the contact shadow under the performer, and let it react to the feet leaving the floor.
    ///
    /// This node used to be positioned once, at load, from the model's bounding box - and then the
    /// dance moved and it did not. Measured on Belly Dance: the hips travel from z -0.44 to -1.47
    /// while the blob stayed at (0.00, 0.03), so the single cue that says "standing on this floor"
    /// ended up a metre and a half behind the feet. The feet themselves were fine the whole time -
    /// instrumented, the lowest sole held within 0.04m of the ground plane - which is why nothing
    /// looked wrong in the numbers and everything looked wrong on screen.
    ///
    /// A constraint rather than a per-frame callback: SceneKit evaluates it inside the render loop,
    /// so the shadow can never be a frame behind the feet it belongs to, and nothing else has to
    /// grow a "tick the shadow" responsibility.
    ///
    /// The size reacts too. A contact shadow that stays the same while the foot lifts is the other
    /// half of the floating look - real contact shadows shrink and soften as the surfaces separate.
    private func followFeet(_ node: SCNNode, groundY: Float) {
        let scheme = BoneScheme.mixamo
        guard let lf = boneNodes[scheme.leftFoot], let rf = boneNodes[scheme.rightFoot] else { return }
        // How high the ankles sit above the floor when standing, so "lift" measures the foot
        // leaving the ground rather than the ankle's own thickness.
        let restAnkleY = min(lf.simdWorldPosition.y, rf.simdWorldPosition.y)
        let fade = max(0.05, modelHeight * 0.10)

        node.constraints = [SCNTransformConstraint(inWorldSpace: true) { [weak lf, weak rf] _, m in
            guard let lf, let rf else { return m }
            let l = lf.simdWorldPosition, r = rf.simdWorldPosition
            // Under whichever foot is lower, biased toward the midpoint: a blob that snaps between
            // the two feet on every step is more distracting than one that trails the weight.
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
        sunNode = sun

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

            controller.stepCameraMove()
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

                // The travelling bright band. Wide and soft rather than a thin line, which read
                // as a stray highlight rather than as content on a screen.
                let bar = pow(0.5 + 0.5 * sin(t * .pi * 2), 4)
                let level = 0.38 + 0.55 * bar
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

            // Knock-down, so the wall never out-shines the performer. It used to be 0.52, which
            // together with `level` capping at 0.55 and the mask's vignette left the wall peaking
            // around 0.20 - the single strongest "this is a venue" cue in the frame, invisible.
            //
            // Raising it is free: this material is `.constant`, so the wall emits and lights
            // nothing. The over-exposure that the levels were originally pulled down to fix was
            // measured on the *performer*, and no emissive set piece contributes to that.
            c.setFillColor(UIColor(white: 0, alpha: 0.18).cgColor)
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

    /// Studio environment map: soft boxes on a dark ground, which is what puts a readable
    /// specular streak on armour and eyes rather than a single blown highlight.
    static let studioEnvironment: UIImage = {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // Dark ground
            c.setFillColor(UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            // Overhead soft box
            let topGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [UIColor.white.withAlphaComponent(0.3).cgColor, UIColor.clear.cgColor] as CFArray,
                                    locations: [0, 1])!
            c.drawLinearGradient(topGrad, start: .zero, end: CGPoint(x: 0, y: size.height * 0.4), options: [])

            // Strip lights either side - these are what draw the long reflections down armour
            // and catch the eyes.
            c.setShadow(offset: .zero, blur: 20, color: UIColor.white.cgColor)
            c.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 20, height: 180))    // left strip
            c.fill(CGRect(x: 450, y: 40, width: 20, height: 180))   // right strip

            // Faint bounce off the floor
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
            // 0.85 from 30% out left the wall's edges at about 3% brightness. The vignette is
            // here to frame the performer, not to erase the set.
            let vig = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.62).cgColor]
            c.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: vig as CFArray, locations: [0.42, 1])!,
                                 startCenter: CGPoint(x: size.width / 2, y: size.height * 0.55), startRadius: 0,
                                 endCenter: CGPoint(x: size.width / 2, y: size.height * 0.55),
                                 endRadius: size.width * 0.62, options: [])
            let fade = [UIColor.clear.cgColor, UIColor.black.cgColor]
            c.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: fade as CFArray, locations: [0, 0.55])!,
                                 start: CGPoint(x: 0, y: size.height * 0.45), end: .zero, options: [])
        }
    }()

    /// Fallback procedural sky background
    /// Where the sky meets the ground.
    ///
    /// The fog is set to exactly this colour, and that is the whole mechanism behind the outdoor
    /// look: the plaza is a finite plane, and it is fog matching the horizon that makes its far
    /// edge disappear instead of ending in a hard line. The two were written separately once - a
    /// pale blue fog against a warm horizon - and the seam was visible right across the frame.
    ///
    /// Sampled from the source photograph by `tools/make_sky.py`, which prints the value whenever
    /// it rebuilds the dome; paste it here after changing the photo.
    static let skyHorizon: (Double, Double, Double) = (0.65, 0.74, 0.78)

    /// The skyline strip: buildings and trees in silhouette, tiled around the horizon ring.
    ///
    /// `v = 0` is the top of the strip and `v = 1` the base, matching the UVs `addSkyline` writes,
    /// so everything is drawn standing on the bottom edge of the image.
    ///
    /// Colours sit near `skyHorizon` rather than at black: distant objects are washed out by the air
    /// in front of them, and a hard black skyline reads as a cut-out pasted onto the photo. Alpha
    /// falls off toward the top of each shape for the same reason - the higher a distant object, the
    /// more haze between it and the eye. Shapes are kept narrow and numerous; a handful of wide ones
    /// reads as a nearby fence however pale it is painted.
    static let skylineTexture: UIImage = {
        let w = 2048, h = 256
        let size = CGSize(width: w, height: h)
        let hz = skyHorizon

        var seed: UInt64 = 0x5C0FFEE          // fixed, so the skyline is the same every launch
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }

        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.clear(CGRect(origin: .zero, size: size))

            /// One silhouette, filled with a vertical haze gradient over the whole strip height.
            /// Gradient over the strip, not over the shape: two buildings of different heights whose
            /// tops shaded identically would both read as the same distance away.
            func fill(_ path: CGPath, tint: CGFloat) {
                c.saveGState()
                c.addPath(path)
                c.clip()
                let lo = UIColor(red: CGFloat(hz.0) * tint, green: CGFloat(hz.1) * (tint + 0.03),
                                 blue: CGFloat(hz.2) * (tint + 0.10), alpha: 0.95).cgColor
                let hi = UIColor(red: CGFloat(hz.0) * (tint + 0.22), green: CGFloat(hz.1) * (tint + 0.26),
                                 blue: CGFloat(hz.2) * (tint + 0.34), alpha: 0.60).cgColor
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                   colors: [hi, lo] as CFArray, locations: [0, 1])!
                c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                c.restoreGState()
            }

            // Two passes of buildings: a paler set further back, then a nearer, darker set over it.
            // One row of boxes all at the same depth is what makes a procedural skyline look like a
            // barcode; overlapping roof lines are most of what sells depth here.
            for pass in 0..<2 {
                let far = pass == 0
                let tint: CGFloat = far ? 0.62 : 0.40
                var x: CGFloat = -60
                while x < size.width + 60 {
                    let bw = (far ? 22 : 30) + rnd() * (far ? 46 : 62)
                    let bh = (far ? 46 : 62) + rnd() * (far ? 74 : 118)
                    let rect = CGRect(x: x, y: size.height - bh, width: bw, height: bh)
                    let p = CGMutablePath()
                    p.addRect(rect)
                    // A few get a setback or a mast, so the roofline is not a row of flat lids.
                    if rnd() < 0.3 {
                        let iw = bw * (0.24 + rnd() * 0.3)
                        p.addRect(CGRect(x: rect.midX - iw / 2, y: rect.minY - 10 - rnd() * 30,
                                         width: iw, height: 24))
                    }
                    fill(p, tint: tint)
                    x += bw + (far ? 3 : 6) + rnd() * (far ? 20 : 40)
                }
            }

            // Tree clumps along the base, in front of everything: they hide the row of foundations,
            // which is the one line a viewer would read as the bottom edge of a flat image.
            var tx: CGFloat = -40
            while tx < size.width + 40 {
                let r = 30 + rnd() * 34
                let p = CGMutablePath()
                for k in 0..<3 {
                    let ox = CGFloat(k - 1) * r * 0.68
                    let rr = r * (k == 1 ? 1 : 0.78)
                    p.addEllipse(in: CGRect(x: tx + ox - rr, y: size.height - rr * 1.45,
                                            width: rr * 2, height: rr * 2))
                }
                fill(p, tint: 0.34)
                tx += r * 1.15 + rnd() * 30
            }
        }
    }()

    /// Fallback dome, used only when `sky_dome.jpg` is missing: a plain vertical gradient ending on
    /// `skyHorizon`. Deliberately plain - a procedural sunset was tried here, and because the camera
    /// only ever sees the band around the horizon, the entire sky read as red.
    private static func makeSkyBackdrop() -> UIImage {
        let size = CGSize(width: 512, height: 256)
        let hz = skyHorizon
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.13, green: 0.31, blue: 0.66, alpha: 1).cgColor,
                          UIColor(red: 0.46, green: 0.67, blue: 0.89, alpha: 1).cgColor,
                          UIColor(red: CGFloat(hz.0), green: CGFloat(hz.1), blue: CGFloat(hz.2), alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.42, 0.5])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height),
                                             options: [.drawsAfterEndLocation])
        }
    }
}
