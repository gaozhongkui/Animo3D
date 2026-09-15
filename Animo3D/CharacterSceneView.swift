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

    let scene = SCNScene()
    internal(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // Character unit height (for AR scaling)
    /// Which bones this character has and what they are called.
    ///
    /// Was a constant back when every character was a Mixamo rig. An imported `.vrm` names its
    /// nodes whatever its author chose, so the scheme is read out of the file's own humanoid table
    /// at install time and everything downstream keeps addressing bones by name as before.
    private(set) var scheme = BoneScheme.mixamo
    /// The VRM root, when the mounted character is an imported one. It drives its own hair.
    private(set) var vrmNode: SCNNode?
    /// The bones the camera measures the pose against - see `posedBounds()`.
    private var boundsNodes: [SCNNode] = []
    /// An imported model's humanoid bones, keyed by the name a `.vrma` calls them. Empty for the
    /// bundled characters, which answer through `MixamoBoneMap` instead.
    private var vrmHumanoid: [String: SCNNode] = [:]
    var groundEnabled = false   // Ground + top-down view enabled only for large performance view; disabled for thumbnails/small cards
    var contactShadowOnly = false   // Detail page: Only add contact shadow under feet (to give grounding sense), no dark floor
    private var lightsAdded = false

    /// Only hair swings. A VRoid rig names every secondary bone `J_Sec_*`, which is also the
    /// bust, the skirt, the coat, the sleeves and the hood strings - `char_VRM_6` alone carries
    /// over a hundred of them. Driving all of those from one set of constants is not "basic hair
    /// physics", it is a whole cloth solver, so this takes the hair chains and leaves the rest
    /// skinned-but-static, exactly as before.
    private static let hairBonePrefix = "J_Sec_Hair"

    /// One link of a hair chain, simulated as a single particle sitting at the bone's tail.
    private struct SpringBone {
        let node: SCNNode
        /// Where the tail sits in the bone's own space: the next link's position, so the chain
        /// uses the model's real segment lengths instead of one guessed constant.
        let localTail: simd_float3
        /// The bone's orientation in its parent's space with no physics applied. Every frame
        /// restarts from here, so the solver reads the pose the animation asks for and writes a
        /// delta on top of it; integrating on its own output instead lets the chain drift away.
        let restLocalRotation: simd_quatf
        var current: simd_float3
        var prev: simd_float3
    }
    private var springBones: [SpringBone] = []
    /// `install()` rebuilds the chains on the main thread while `updatePhysics()` walks them on
    /// SceneKit's render thread - switching character mid-frame used to be a crash window.
    private let springLock = NSLock()

    @Published var userScale: Float = 1.0 {
        didSet { characterRoot?.simdScale = simd_float3(repeating: userScale) }
    }
    @Published var userRotationY: Float = 0 {
        didSet { characterRoot?.simdEulerAngles.y = userRotationY }
    }

    // Skeletal pose at load time, used for resetting.
    private var bindPose: [(node: SCNNode, orientation: simd_quatf, position: simd_float3)] = []

    func captureBindPose() {
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
            // SceneKit does not read glTF, so a model the user imported takes the other door.
            let parsed = VRMCharacter.isVRM(url)
                ? VRMCharacter.loadScene(at: url)
                : try? SCNScene(url: url, options: [.convertToYUp: false])
            guard let loaded = parsed else {
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
        boundsNodes.removeAll()
        vrmHumanoid.removeAll()
        vrmNode = nil
        isToonCharacter = false
        scheme = .mixamo
        springLock.lock(); springBones.removeAll(); springLock.unlock()
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
        var hairNodes: [SCNNode] = []
        root.removeAllAnimations()
        root.enumerateChildNodes { node, _ in
            for key in node.animationKeys { node.removeAnimation(forKey: key) }
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
                if name.hasPrefix(Self.hairBonePrefix) { hairNodes.append(node) }
                if name.hasPrefix("J_Sec_") { isToonCharacter = true }
                if name.hasPrefix("mixamorig") || name.hasPrefix("J_Sec_") { boundsNodes.append(node) }
            }
        }

        // An imported model has to declare its own skeleton before anything reads one. Everything
        // below - orienting, framing, foot planting - addresses bones through `scheme`, and for a
        // `.vrm` the names in it come from the file.
        if let vrm = VRMCharacter.node(in: loaded) {
            guard let vrmScheme = VRMCharacter.scheme(for: vrm) else {
                NSLog("[Character] imported model has an incomplete humanoid; refusing to mount")
                root.removeFromParentNode()
                characterRoot = nil
                return []
            }
            vrmNode = vrm
            isToonCharacter = true
            scheme = vrmScheme
            // A VRM has no name prefix to search for, and its humanoid set already spans the whole
            // body - which is exactly what framing needs to measure.
            vrmHumanoid = VRMCharacter.humanoidNodes(of: vrm)
            boundsNodes = Array(vrmHumanoid.values)
        }

        sanitizeMaterials(root)
        normalizeOrientation(root)
        setupFrontCamera()

        // Apply user adjustments
        root.simdScale = simd_float3(repeating: userScale)
        root.simdEulerAngles.y = userRotationY

        // Seed the hair particles only now. normalizeOrientation() and the two lines above all
        // move the character in world space, and a particle seeded before them starts the first
        // frame metres away from its bone - which reads as the hair being flung across the stage.
        seedHairPhysics(hairNodes)

        // Fallback height: when bone lookup fails (a Tripo static mesh has no Mixamo skeleton),
        // walk every geometry and convert the 8 corners of its local bounding box to world space.
        // root.boundingBox alone is unreliable - it may exclude children or ignore import scale.
        if modelHeight <= 0.01 { modelHeight = worldBoundingHeight(root) }

        if !lightsAdded { addLights(); lightsAdded = true }
        // Light levels are applied at the end of updateBackgroundAndGround(), after setupGround
        // has built the stage. Setting them here instead would be overwritten immediately.
        updateBackgroundAndGround()   // calls setupGround internally; do not call that separately
        captureBindPose()
        isLoaded = true
        return found.sorted()
    }

    /// The node a `.vrma` means when it names a humanoid bone.
    ///
    /// A take is rotations keyed by VRM humanoid name. A bundled character answers through
    /// `MixamoBoneMap`; an imported one answers through the scheme read out of its own file. Every
    /// caller that drives a skeleton goes through here, so neither the player, the retargeter nor
    /// the thumbnail renderer has to know which kind is mounted.
    func humanoidNode(_ vrmBoneName: String) -> SCNNode? {
        if vrmNode != nil { return vrmHumanoid[vrmBoneName] }
        return MixamoBoneMap.humanoid[vrmBoneName].flatMap { boneNodes[$0] }
    }

    /// Build the hair chains from the bones just collected, with the character already in its
    /// final place. Call this from `install()` and nowhere else.
    private func seedHairPhysics(_ nodes: [SCNNode]) {
        var bones: [SpringBone] = []
        bones.reserveCapacity(nodes.count)

        for node in nodes {
            // A link swings toward the next link. The tip of a chain - VRoid spells those
            // `..._end_...` - has nothing to swing toward and is carried by its parent, so it is
            // simulated by proxy and skipped here.
            guard let tip = node.childNodes.first(where: {
                ($0.name ?? "").hasPrefix(Self.hairBonePrefix)
            }) else { continue }
            let localTail = tip.simdPosition
            guard simd_length_squared(localTail) > 1e-8 else { continue }

            let tail = node.simdConvertPosition(localTail, to: nil)
            bones.append(SpringBone(node: node,
                                    localTail: localTail,
                                    restLocalRotation: node.simdOrientation,
                                    current: tail,
                                    prev: tail))
        }

        // Parents first: a link solves against its parent's transform for *this* frame, so a
        // child solved ahead of its parent would be chasing the previous one and the chain would
        // ripple a frame late at every joint.
        bones.sort { depth(of: $0.node) < depth(of: $1.node) }

        springLock.lock(); springBones = bones; springLock.unlock()
    }

    private func depth(of node: SCNNode) -> Int {
        var d = 0
        var n = node.parent
        while let p = n { d += 1; n = p.parent }
        return d
    }

    /// Step the hair chains. Runs once per rendered frame, on SceneKit's render thread.
    ///
    /// Verlet particle per link, constrained to the bone's own length, with the result applied as
    /// a swing *delta* on the pose the `.vrma` player wrote. Everything is scale-relative, so the
    /// pinch gesture does not change how the hair behaves.
    func updatePhysics() {
        guard isLoaded else { return }

        // An imported model states where its own spring bones are and how they behave. That is real
        // data from the file, strictly better than the name matching below, so it drives itself.
        if let vrm = vrmNode {
            VRMCharacter.step(vrm, at: CACurrentMediaTime())
            return
        }

        springLock.lock()
        defer { springLock.unlock() }
        guard !springBones.isEmpty else { return }

        let stiffness: Float = 0.08     // how hard a link is pulled back to the animated pose
        let drag: Float = 0.85          // share of velocity kept each frame
        let sag: Float = 0.03           // gravity, as a fraction of the link's own length

        for i in springBones.indices {
            let node = springBones[i].node
            guard node.parent != nil else { continue }

            // Rest pose first: the parent has already been posed this frame, so this is where the
            // animation on its own would put the tail.
            node.simdOrientation = springBones[i].restLocalRotation
            let origin = node.simdWorldPosition
            let restTail = node.simdConvertPosition(springBones[i].localTail, to: nil)
            let length = simd_length(restTail - origin)
            guard length > 1e-5 else { continue }

            // A character that was just swapped, rescaled or moved leaves the particle nowhere
            // near its bone. Snap it instead of letting it whip back across the head.
            if simd_distance(springBones[i].current, origin) > length * 6 {
                springBones[i].current = restTail
                springBones[i].prev = restTail
            }

            let velocity = (springBones[i].current - springBones[i].prev) * drag
            let pull = (restTail - springBones[i].current) * stiffness
            var next = springBones[i].current + velocity + pull + simd_float3(0, -sag * length, 0)

            // Hold the particle on the sphere of the bone's length: the link rotates, it does not
            // stretch.
            let dir = next - origin
            guard simd_length_squared(dir) > 1e-10 else { continue }
            next = origin + simd_normalize(dir) * length

            springBones[i].prev = springBones[i].current
            springBones[i].current = next

            // Apply the swing on top of the rest orientation. Rebuilding the orientation outright
            // (look(at:up:)) would throw away the bone's own twist and flip whenever the up vector
            // lined up with the bone.
            let from = simd_normalize(restTail - origin)
            let to = simd_normalize(next - origin)
            let d = simd_dot(from, to)
            // Skip a no-op, and skip the antipodal case where the from->to rotation is undefined.
            guard d < 0.99999, d > -0.99999 else { continue }
            node.simdWorldOrientation = simd_quatf(from: from, to: to) * node.simdWorldOrientation
        }
    }

    // MARK: - Stage

    /// One stage: the sky the performance happens under, the ground it happens on, and the light
    /// that falls on both.
    ///
    /// These are one value rather than a handful of independent settings because they are not
    /// independent. The fog has to be the colour the dome fades to at eye level, or the ground ends
    /// in a hard line against the sky; the skyline ring has to stand inside the fog's range to read
    /// as distant; and the light levels and the camera grade are calibrated against that particular
    /// sky, not in general. Pairing the sky of one stage with the ground of another gives none of
    /// that, which is why a stage is picked whole.
    ///
    /// Distances are in body heights, not metres: a character is mounted at whatever scale its
    /// source file was authored in, and everything here has to hold for all of them.
    struct StageSpec {
        /// The surface the performer stands on - a finite plane, tiled.
        struct Ground {
            let texture: () -> UIImage
            let repeats: Float              // times the texture tiles across the plane
            let extent: Float               // the plane's side
            let inlay: (() -> UIImage)?     // decal centred under the performer, nil for none
            let inlayExtent: Float          // its side
        }

        /// A ring of distant silhouette standing on the ground, which is what fills the gap
        /// between the two: without it the eye reads sky meeting ground and nothing in between.
        struct Skyline {
            let texture: () -> UIImage
            let radius: Float               // how far out the ring stands
            let band: Float                 // the strip's height
            let repeats: Float              // times the strip goes round
        }

        let id: String
        let sky: () -> UIImage              // 2:1 equirectangular dome
        let horizon: UIColor                // what the dome fades to at eye level; the fog takes it
        let fogNear: Float                  // where the fade starts, from the camera
        let fogFar: Float                   // and where it is complete
        let ground: Ground
        let skyline: Skyline?

        /// One rig, not one per kind of character.
        ///
        /// A per-character rig was tried, because a VRoid model blows out under the levels a
        /// photographed one is calibrated for (measured on VRM 4 against Erika: 33% of the body
        /// clipped to pure white against 0.07%, the dress a flat white shape with no fabric left
        /// in it). Dimming the rig for those characters fixed the character and broke the stage:
        /// the paving dropped 17% while the sky - a background image, which no light touches -
        /// stayed put, so the same plaza came out two different brightnesses depending on who was
        /// dancing on it. The light belongs to the stage; the fix belongs on the model, and is
        /// `toonAlbedoScale` in `sanitizeMaterials`.
        let light: LightLevels
        let grade: CameraGrade
    }

    /// The stages the app ships.
    enum Stage {
        /// Daylight plaza: paved ground under an open sky, a city on the horizon.
        ///
        /// Every number here was measured rather than chosen - see `LightLevels` and the fog
        /// distances below for what each one was fixing.
        static let plaza = StageSpec(
            id: "plaza",
            // A proper 2:1 equirectangular dome, built from the source photograph by
            // tools/make_sky.py: its sky and treeline only, with the paving discarded. Setting the
            // photo itself here - 704x1503, portrait, plaza included - is what wrapped a picture of
            // the ground across the sky.
            sky: { UIImage(named: "sky_dome") ?? CharacterSceneView.skyBackdrop() },
            horizon: UIColor(red: CGFloat(CharacterSceneView.skyHorizon.0),
                             green: CGFloat(CharacterSceneView.skyHorizon.1),
                             blue: CGFloat(CharacterSceneView.skyHorizon.2), alpha: 1),
            // Starts beyond the performer (roughly 2.3 body heights from the camera); nearer than
            // that and the fog washes the character out along with the ground.
            fogNear: 3.0,
            // And ends a long way out. At 9 everything past the performer was already
            // horizon-coloured, which left nowhere to put a distant skyline - anything far enough
            // away to read as distant was also erased. The plaza is 30 to its edge, so it still
            // ends inside the fog and its far edge never shows.
            fogFar: 22.0,
            ground: StageSpec.Ground(
                texture: { CharacterSceneController.plazaTexture },
                // 55 repeats of a 4x4 block: a ~0.45m slab, sixteen of them per tile.
                repeats: 55, extent: 60,
                inlay: { CharacterSceneController.plazaInlayTexture }, inlayExtent: 5),
            skyline: StageSpec.Skyline(
                texture: { CharacterSceneView.skylineTexture },
                radius: 13, band: 3.2, repeats: 4),
            light: LightLevels(key: 380, fill: 150, rim: 300, sun: 180, ibl: 0.25,
                               shadowAlpha: 0.45, rimShader: 0.04),
            grade: CameraGrade(exposureOffset: 0.0, whitePoint: 1.0, contrast: 0.08,
                               vignetting: 0.22, bloom: 0.05, bloomThreshold: 1.1))

        static let all: [StageSpec] = [plaza]
    }

    /// The stage on screen. Setting it rebuilds the sky, the ground and the rig together.
    @Published var stage: StageSpec = Stage.plaza {
        didSet { updateBackgroundAndGround() }
    }

    /// Whether the mounted character is a VRoid-style model rather than a photographed one.
    ///
    /// Read off the skeleton rather than off the catalogue: a VRoid rig carries `J_Sec_*` secondary
    /// bones for hair and cloth that no Mixamo rig has, and an imported `.vrm` is one by definition.
    /// The catalogue id would work for the seven bundled ones and not at all for an imported file.
    private(set) var isToonCharacter = false

    /// How far a VRoid model's albedo is pulled back - measured, see `sanitizeMaterials`.
    private static let toonAlbedoScale: CGFloat = 0.68

    // MARK: - Lighting levels

    /// Intensities for the four rig lights plus the image-based light.
    ///
    /// These used to be written from three different places - install(), the stage setup and
    /// addLights() - each with its own numbers, and the later writer silently won, so the earlier
    /// adjustments never took effect at all. Everything reads this one description now.
    struct LightLevels {
        let key: CGFloat          // Front-left spot
        let fill: CGFloat         // Front-right omni
        let rim: CGFloat          // Back spot, draws the silhouette
        let sun: CGFloat          // Directional, casts the ground shadow
        let ibl: CGFloat          // lightingEnvironment.intensity, 0 disables it
        let shadowAlpha: CGFloat
        let rimShader: Float      // Strength of the additive fresnel rim in the fragment modifier
    }

    /// A stage's numbers were not guessed: every source was rendered on its own offline and
    /// measured against the neutral three-point rig `tools/render_thumbs.swift` uses, which is the
    /// reference for "what does this character actually look like" (mean luma 0.22, median 0.17).
    /// Anything brighter and Erika's dark olive tunic renders as pale grey - which is what made
    /// every character look washed out and flat no matter how far the exposure was pulled down.
    private var lightLevels: LightLevels { stage.light }

    /// The camera's tone mapping.
    ///
    /// Daylight: neutral exposure, white stays white, a touch of contrast and bloom. A dark-stage
    /// grade was tried here - `whitePoint` well above 1, to pull light skin and pale cloth back off
    /// the clip point - and on this scene that curve maps a luminance of 1.0 to about 0.43, so the
    /// white cumulus in the sky dome came out the same grey as the sky behind them and the clouds
    /// simply disappeared. It read as "the sky texture is wrong"; the texture was fine.
    struct CameraGrade {
        let exposureOffset: CGFloat
        let whitePoint: CGFloat
        let contrast: CGFloat
        let vignetting: CGFloat
        let bloom: CGFloat
        let bloomThreshold: CGFloat
    }

    private var cameraGrade: CameraGrade { stage.grade }

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
        // Only the full stage paints a background. Thumbnails and the live dance cards draw over a
        // SwiftUI backdrop, so a scene background here covers that card with a flat slab of colour.
        scene.background.contents = groundEnabled ? stage.sky() : nil

        // Fog: the ground fades into the sky in the distance, which is what fuses the two and
        // gives the scene its depth (large performance view only).
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
            setupGround(root)
        }
        // Last, so the levels match the stage setupGround just built or tore down.
        applyLightLevels()
        applyCameraGrade()
    }

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private var footShadows: [SCNNode] = []
    private var skylineNode: SCNNode?           // Distant buildings and trees on the horizon
    private var inlayNode: SCNNode?             // Stone medallion under the performer

    // All four rig lights are held here. Two of them used to be unreachable - `ambientLight` was
    // declared but never assigned (every write to it did nothing) and the fill/rim lights were
    // never stored - so the stage could only dim half the rig and the rest kept blasting.
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
    /// camera round to the performer's back and out through the scenery. It is a bounded swing
    /// now: a slow arc either side of wherever the shot was framed,
    /// with the distance breathing on a longer period so it does not feel like a turntable.
    var isAutoOrbiting = true
    private var orbitClock: Float = 0
    /// Azimuth and radius of the framing `setupFrontCamera` chose, captured on the first frame so
    /// the move starts exactly where the shot already is and never snaps.
    private var orbitBaseAzimuth: Float?
    private var orbitBaseRadius: Float = 0
    /// Smoothed orbit target and distance - see `stepCameraMove()`.
    private var orbitLook: simd_float3?
    private var orbitRadius: Float = 0
    /// Width / height of the view the stage is drawn into, so a pose can be tested against the real
    /// frame rather than an assumed one. Written by the view each frame; the default is a phone
    /// held upright.
    var viewportAspect: Float = 0.46

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
            orbitRadius = r
        }
        guard let base = orbitBaseAzimuth else { return }

        orbitClock += 1.0 / 30.0                     // the display link runs at 30
        let azimuth = base + sin(orbitClock * 0.20) * orbitSwing

        // Where the performance actually is this frame.
        //
        // The orbit used to circle `stageCenter` and stare at a fixed waist height, both fixed at
        // install time off a standing character. A take that travels, spins or drops then walks the
        // dancer out of a shot that never noticed - on this stage Belly Dance put half of her past
        // the right edge of the screen.
        let standing = simd_float3(stageCenter.x, feetY + modelHeight * 0.48, stageCenter.z)
        var targetLook = standing
        var targetRadius = orbitBaseRadius
        if let b = posedBounds() {
            let c = (b.min + b.max) * 0.5
            // Horizontally the camera follows all the way: a dancer who travels stays centred.
            // Vertically only partly - riding a jump all the way up takes the floor out of frame
            // with it, and the floor is most of what says this is a stage.
            targetLook = simd_float3(c.x, standing.y + (c.y - standing.y) * 0.45, c.z)
            // Never closer than the framing the stage was composed at; only further out, and only
            // when a pose would otherwise spill past an edge.
            targetRadius = max(orbitBaseRadius,
                               distance(forHalfExtent: (b.max - b.min) * 0.5,
                                        aspect: viewportAspect, margin: 1.25, fieldOfView: 55))
        }

        // Eased, and lopsided the same way the card's follow is: back off quickly, close in slowly.
        var look = orbitLook ?? targetLook
        look += (targetLook - look) * 0.10
        orbitLook = look
        orbitRadius += (targetRadius - orbitRadius) * (targetRadius > orbitRadius ? 0.20 : 0.03)

        // Distance breathes on a longer period than the swing, so the two never line up into an
        // obvious loop.
        let radius = orbitRadius * (1 + sin(orbitClock * 0.13) * 0.05)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        cam.simdPosition.x = look.x + sin(azimuth) * radius
        cam.simdPosition.z = look.z + cos(azimuth) * radius
        // Keep the same height above the subject the composed shot had, so following a jump does
        // not flatten the camera into a level stare.
        cam.simdPosition.y = look.y + modelHeight * 0.57
        cam.look(at: SCNVector3(look))
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
        m.diffuse.contents = spec.texture()
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

        // A big finite plane rather than SCNFloor. SCNFloor's texture coordinates are its own
        // business - paving on it came out as one smeared slab - while a plane's UVs run 0...1
        // across its extent, so the repeat count is exactly what is asked for. The fog hides
        // the far edge, and there is no reflection to flatten the paving into a sheet of sky.
        let h = max(modelHeight, 0.1)
        let spec = stage.ground
        let ground = SCNPlane(width: CGFloat(h * spec.extent), height: CGFloat(h * spec.extent))
        let gm = ground.firstMaterial!
        gm.diffuse.contents = spec.texture()
        gm.diffuse.wrapS = .repeat
        gm.diffuse.wrapT = .repeat
        gm.diffuse.contentsTransform = SCNMatrix4MakeScale(spec.repeats, spec.repeats, 1)
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
        if let inlayTexture = spec.inlay {
            let inlay = SCNPlane(width: CGFloat(h * spec.inlayExtent), height: CGFloat(h * spec.inlayExtent))
            let im = inlay.firstMaterial!
            im.diffuse.contents = inlayTexture()
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
            let blobW = min(footSpan * 2.4, max(modelHeight, 0.1) * 0.75) * 1.15
            let blob = SCNPlane(width: CGFloat(blobW), height: CGFloat(blobW * 0.62))
            let bm = blob.firstMaterial!
            bm.diffuse.contents = Self.contactShadowTextureStrong
            // The body pool the per-foot ones sit inside; at full strength the two doubled up
            // into a single dark smear.
            bm.transparency = 0.8
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
        if let ring = stage.skyline {
            addSkyline(ring, feetY: minY, height: max(modelHeight, 0.1))
        } else {
            skylineNode?.removeFromParentNode(); skylineNode = nil
        }
    }

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
    func sanitizeMaterials(_ root: SCNNode) {
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

                // VRoid models are authored with an albedo no real surface has: white cloth comes
                // in at nearly 1.0, where real white cloth sits around 0.7-0.8. Lit by a rig
                // calibrated on photographed characters it has nowhere left to go and clips - and
                // clipping is what erases the folds, the hem and the buttons, leaving a flat white
                // shape. Scaling it here rather than dimming the lights keeps the correction on the
                // thing that is actually wrong, and leaves the ground and the sky alone.
                if isToonCharacter {
                    material.multiply.contents = UIColor(white: Self.toonAlbedoScale, alpha: 1)
                }

                material.shaderModifiers = [
                    .fragment: Self.rimLightModifier
                ]
                material.setValue(lightLevels.rimShader, forKey: "rimStrength")
            }
        }
    }

    /// Calculate the actual Up/Left/Forward axes using bone positions, forcing the root node to be
    /// Y-up and facing +Z. Do not rely on USD's upAxis metadata (that metadata is unreliable).
    func normalizeOrientation(_ root: SCNNode) {
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

    // MARK: - Framing a posed skeleton

    /// World bounds of the skeleton *as it is posed right now*, padded out to the silhouette.
    ///
    /// Bones rather than `boundingBox`: SceneKit reports a skinned geometry's bounds from its bind
    /// pose, so that box never moves however far the take throws the skeleton - which is the exact
    /// blind spot this exists to cover.
    func posedBounds() -> (min: simd_float3, max: simd_float3)? {
        guard isLoaded, modelHeight > 0, !boundsNodes.isEmpty else { return nil }
        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
        for node in boundsNodes {
            let p = node.simdWorldPosition
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }

        // A joint sits inside the body: the skull bone is well below the top of the hair, the ankle
        // well above the sole, the wrist short of the fingertips. Pad out to what is drawn, with
        // the extra headroom hair actually needs.
        let side = modelHeight * 0.09
        lo -= simd_float3(side, modelHeight * 0.06, side)
        hi += simd_float3(side, modelHeight * 0.13, side)
        return (lo, hi)
    }

    /// Aim the camera at the pose currently on the skeleton, so the whole figure lands inside an
    /// image of the given aspect ratio (width / height).
    ///
    /// `setupFrontCamera()` frames the *rest* pose once, at install time, and then never moves. Any
    /// take that lifts, tips or travels the hips - a jump, a handstand, a roll - leaves the figure
    /// half outside the frame or out of it entirely, which is what produced cards showing a shin,
    /// and one card showing nothing at all.
    ///
    /// The narrower default field of view is deliberate: 62 degrees is a wide-angle lens pointed at
    /// a person from two metres, and it stretched whichever limb was nearest the camera.
    func frameCameraOnPose(aspect: Float, margin: Float = 1.1, fieldOfView: CGFloat = 42) {
        guard let b = posedBounds() else { return }
        frameCamera(on: b, aspect: aspect, margin: margin, fieldOfView: fieldOfView)
    }

    /// Same framing, against bounds the caller worked out for itself.
    func frameCamera(on b: (min: simd_float3, max: simd_float3),
                     aspect: Float, margin: Float = 1.1, fieldOfView: CGFloat = 42) {
        let center = (b.min + b.max) * 0.5
        let half = (b.max - b.min) * 0.5
        placeCamera(center: center,
                    distance: distance(forHalfExtent: half, aspect: aspect, margin: margin,
                                       fieldOfView: fieldOfView),
                    fieldOfView: fieldOfView)
    }

    /// How far back the camera has to sit for a box of this size to fit the frame.
    private func distance(forHalfExtent half: simd_float3, aspect: Float, margin: Float,
                          fieldOfView: CGFloat) -> Float {
        // The field of view is vertical, so a wide pose has to be expressed as the height it needs.
        let needed = max(half.y, half.x / max(aspect, 0.01)) * margin
        let fov = Float(fieldOfView) * .pi / 180
        return needed / tan(fov * 0.5) + half.z
    }

    private func placeCamera(center: simd_float3, distance: Float, fieldOfView: CGFloat) {
        guard let cam = cameraNode, let camera = cam.camera else { return }
        camera.projectionDirection = .vertical
        camera.fieldOfView = fieldOfView
        cam.simdPosition = simd_float3(center.x, center.y, center.z + distance)
        cam.look(at: SCNVector3(center))
        camera.zNear = Double(max(distance * 0.01, 0.001))
        camera.zFar = Double(distance * 4 + modelHeight * 10)
    }

    // MARK: - Following a dancer

    /// A camera that rides the performance instead of standing off far enough to contain all of it.
    ///
    /// Framing a take on the union of every pose it strikes keeps the dancer in shot, but pays for
    /// it everywhere: one leap in second twelve pushes the camera back for the whole dance, and on
    /// a card that small the dancer ends up a thumbnail inside a thumbnail. This tracks the pose
    /// that is actually on screen and keeps it filling the frame.
    private struct CameraFollow {
        let aspect: Float, margin: Float, fieldOfView: CGFloat
        var center: simd_float3
        var distance: Float
    }
    private var follow: CameraFollow?

    /// Take the camera off its fixed mount. `stepCameraFollow()` then moves it every frame.
    func beginCameraFollow(aspect: Float, margin: Float = 1.12, fieldOfView: CGFloat = 42) {
        guard let b = posedBounds() else { return }
        let half = (b.max - b.min) * 0.5
        follow = CameraFollow(aspect: aspect, margin: margin, fieldOfView: fieldOfView,
                              center: (b.min + b.max) * 0.5,
                              distance: distance(forHalfExtent: half, aspect: aspect,
                                                 margin: margin, fieldOfView: fieldOfView))
        stepCameraFollow()
    }

    func endCameraFollow() { follow = nil }

    /// One step of the follow. Call it once per rendered frame, after the pose is written.
    ///
    /// Two things keep this from looking like a camera operator with hiccups. It eases toward the
    /// pose rather than snapping to it, so a hand flicking out for three frames does not throw the
    /// shot. And the easing is deliberately lopsided - pulling back is quick, pushing in is slow -
    /// because losing a limb off the edge is glaring while a beat of extra air around the dancer is
    /// not. Symmetric rates give the shot a breathing, zooming-in-and-out quality that is worse
    /// than either error.
    func stepCameraFollow() {
        guard var f = follow, let b = posedBounds() else { return }
        let half = (b.max - b.min) * 0.5
        let targetCenter = (b.min + b.max) * 0.5
        let targetDistance = distance(forHalfExtent: half, aspect: f.aspect,
                                      margin: f.margin, fieldOfView: f.fieldOfView)

        f.center += (targetCenter - f.center) * 0.12
        f.distance += (targetDistance - f.distance) * (targetDistance > f.distance ? 0.25 : 0.04)
        follow = f
        placeCamera(center: f.center, distance: f.distance, fieldOfView: f.fieldOfView)
    }

    /// Set a fixed front fullscreen camera using bone positions (more reliable than bounding boxes, not affected by skeleton extensions).
    func setupFrontCamera() {
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

    /// Tint the rim light, the back spot that draws the silhouette.
    ///
    /// A card is a dark stage with one coloured glow behind the dancer's shoulders, painted by
    /// `CardBackdrop`. Lighting the figure with a white rim on top of that is what made it read as
    /// a cut-out pasted onto the art: the light in the picture and the light on the person came
    /// from different places. Hand in the card's own accent and the two become one light.
    ///
    /// Pass nil for white - the stage rig's own colour, which this must not disturb.
    func setRimTint(_ color: UIColor?) {
        rimLight?.color = color ?? UIColor.white
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

        init(controller: CharacterSceneController) {
            self.controller = controller
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            if let view = renderer as? SCNView, view.bounds.height > 1 {
                controller.viewportAspect = Float(view.bounds.width / view.bounds.height)
            }
            controller.updatePhysics()
            controller.stepCameraMove()

            // Hair physics used to be stepped here, on a `VRMNode` mounted straight from a `.vrm`
            // file. Nothing mounts one any more - every character is a `.scn` built by
            // `tools/auto_rig.py` - so this only ever saw a nil cast. The spring solver those
            // `.scn` files needed is now `controller.updatePhysics()`, called above. It drives the
            // `J_Sec_Hair*` chains only; the other `J_Sec_*` bones (bust, skirt, sleeves) are
            // still skinned but undriven.
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

        // MARK: Gestures
        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard g.state == .changed else { return }
            let s = Float(g.scale)
            controller.userScale = max(0.1, min(controller.userScale * s, 5.0))
            g.scale = 1.0
        }

        @objc func handleRotate(_ g: UIRotationGestureRecognizer) {
            guard g.state == .changed else { return }
            controller.userRotationY -= Float(g.rotation)
            g.rotation = 0
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

        // Add gestures for manual model adjustment (Scale & Rotate)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
        view.addGestureRecognizer(rotate)

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
        // The take is sampled at 30fps and the skeleton is driven at 30fps, so half of
        // the frames a 60Hz view draws - and three quarters of a 120Hz one's - are the same pose
        // rendered again. Nothing on screen moves between them, and during a recording that
        // duplicated pass competes with the capture render for the same main thread. `playbackFPS`
        // has said 30 since it was written; it had simply never been applied to a view.
        view.preferredFramesPerSecond = DeviceTier.playbackFPS
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
