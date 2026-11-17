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

typealias StageSpec = CharacterSceneController.StageSpec

final class CharacterSceneController: ObservableObject, BoneRig {

    let scene = SCNScene()
    internal(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // Character unit height (for AR scaling)

    /// Which bones this character has and what they are called.
    private(set) var scheme = BoneScheme.mixamo
    /// The VRM root, when the mounted character is an imported one. It drives its own hair.
    private(set) var vrmNode: SCNNode?
    /// The bones the camera measures the pose against - see `posedBounds()`.
    private var boundsNodes: [SCNNode] = []
    /// An imported model's humanoid bones, keyed by the name a `.vrma` calls them.
    private var vrmHumanoid: [String: SCNNode] = [:]

    var groundEnabled = false   // Ground + top-down view enabled only for large performance view
    var contactShadowOnly = false   // Detail page: Only add contact shadow under feet, no dark floor
    private var lightsAdded = false
    private var facialSoul: FacialSoul?

    // Delegated Managers
    let springSolver = SpringBoneSolver()
    lazy var environmentManager = SceneEnvironmentManager(scene: scene)
    let cameraController = SceneCameraController()

    @Published var isSceneActive: Bool = true

    private var memoryObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    init() {
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleLowMemory()
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSceneActive = false
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSceneActive = true
        }
    }

    deinit {
        if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        tearDown()
    }

    func pause() {
        isSceneActive = false
    }

    func resume() {
        isSceneActive = true
    }

    /// Explicitly unmount and purge 3D character nodes, materials, and geometries from GPU memory.
    func tearDown() {
        springSolver.tearDown()
        boneNodes.removeAll()
        boundsNodes.removeAll()
        vrmHumanoid.removeAll()
        bindPose.removeAll()
        vrmNode = nil
        facialSoul = nil

        purgeNode(characterRoot)
        characterRoot = nil
        isLoaded = false
    }

    /// Purges materials, geometries, and child nodes to ensure Metal GPU texture resources are freed immediately.
    private func purgeNode(_ root: SCNNode?) {
        guard let root else { return }
        root.enumerateChildNodes { node, _ in
            node.removeAllAnimations()
            if let geometry = node.geometry {
                for mat in geometry.materials {
                    mat.diffuse.contents = nil
                    mat.normal.contents = nil
                    mat.roughness.contents = nil
                    mat.metalness.contents = nil
                    mat.ambientOcclusion.contents = nil
                    mat.emission.contents = nil
                    mat.transparent.contents = nil
                }
                node.geometry = nil
            }
            node.skinner = nil
            node.removeFromParentNode()
        }
        root.removeAllAnimations()
        root.removeFromParentNode()
    }

    private func handleLowMemory() {
        SCNTransaction.flush()
    }

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

    func resetToRestPose() {
        for b in bindPose {
            b.node.simdOrientation = b.orientation
            b.node.simdPosition = b.position
        }
    }

    func reattachToScreenScene() {
        arGroundY = nil
        guard let root = characterRoot else { return }
        if root.parent !== scene.rootNode {
            root.removeFromParentNode()
            scene.rootNode.addChildNode(root)
        }
    }

    private static let parseQueue = DispatchQueue(label: "com.animo3d.scene.parse")

    static func loadSceneFile(at url: URL, warmUp: Bool = false) -> SCNScene? {
        parseQueue.sync {
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

    static func warmUp(_ scene: SCNScene) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        _ = r.prepare(scene.rootNode, shouldAbortBlock: nil)
    }

    @discardableResult
    func install(_ loaded: SCNScene) -> [String] {
        purgeNode(characterRoot)
        boneNodes.removeAll()
        boundsNodes.removeAll()
        vrmHumanoid.removeAll()
        vrmNode = nil
        isToonCharacter = false
        scheme = .mixamo
        springSolver.tearDown()
        isLoaded = false

        let root = loaded.rootNode
        scene.rootNode.addChildNode(root)
        characterRoot = root

        var found: [String] = []
        var secondaryNodes: [SCNNode] = []
        root.removeAllAnimations()
        root.enumerateChildNodes { node, _ in
            for key in node.animationKeys { node.removeAnimation(forKey: key) }
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
                if name.hasPrefix(SpringBoneSolver.secondaryBonePrefix) { secondaryNodes.append(node) }
                if name.hasPrefix("J_Sec_") { isToonCharacter = true }
                if name.hasPrefix("mixamorig") || name.hasPrefix("J_Sec_") { boundsNodes.append(node) }
            }
        }

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
            vrmHumanoid = VRMCharacter.humanoidNodes(of: vrm)
            boundsNodes = Array(vrmHumanoid.values)
        }

        sanitizeMaterials(root)
        normalizeOrientation(root)
        setupFrontCamera()
        setupColliders()

        root.simdScale = simd_float3(repeating: userScale)
        root.simdEulerAngles.y = userRotationY

        seedSecondaryPhysics(secondaryNodes)

        if modelHeight <= 0.01 { modelHeight = worldBoundingHeight(root) }

        facialSoul = FacialSoul(rootNode: root, headNode: humanoidNode("head"))

        if !lightsAdded { addLights(); lightsAdded = true }
        updateBackgroundAndGround()
        captureBindPose()
        isLoaded = true
        return found.sorted()
    }

    func humanoidNode(_ vrmBoneName: String) -> SCNNode? {
        if vrmNode != nil { return vrmHumanoid[vrmBoneName] }
        return MixamoBoneMap.humanoid[vrmBoneName].flatMap { boneNodes[$0] }
    }

    private func setupColliders() {
        springSolver.setupColliders(modelHeight: modelHeight, humanoidNode: { [weak self] in self?.humanoidNode($0) })
    }

    private func seedSecondaryPhysics(_ nodes: [SCNNode]) {
        springSolver.seedSecondaryPhysics(nodes)
    }

    func updatePhysics() {
        springSolver.updatePhysics(isLoaded: isLoaded, isSceneActive: isSceneActive, vrmNode: vrmNode, facialSoul: facialSoul, userScale: userScale)
    }

    struct StageSpec: Equatable {
        struct Ground {
            let texture: () -> UIImage
            let repeats: Float              // times the texture tiles across the plane
            let extent: Float               // the plane's side
            let inlay: (() -> UIImage)?     // decal centred under the performer, nil for none
            let inlayExtent: Float          // its side
            let tint: UIColor?
        }

        struct Skyline {
            let texture: () -> UIImage
            let radius: Float               // how far out the ring stands
            let band: Float                 // the strip's height
            let repeats: Float              // times the strip goes round
        }

        struct LightLevels {
            let key: CGFloat          // Front-left spot
            let fill: CGFloat         // Front-right omni
            let rim: CGFloat          // Back spot, draws the silhouette
            let sun: CGFloat          // Directional, casts the ground shadow
            let ibl: CGFloat          // lightingEnvironment.intensity, 0 disables it
            let shadowAlpha: CGFloat
            let rimShader: Float      // Strength of the additive fresnel rim in the fragment modifier
            let keyColor: UIColor
            let rimColor: UIColor
        }

        struct CameraGrade {
            let exposureOffset: CGFloat
            let whitePoint: CGFloat
            let contrast: CGFloat
            let vignetting: CGFloat
            let bloom: CGFloat
            let bloomThreshold: CGFloat
        }

        static func == (lhs: StageSpec, rhs: StageSpec) -> Bool {
            lhs.id == rhs.id
        }

        let id: String
        let name: String
        let icon: String                    // SF Symbol for its chip
        let sky: () -> UIImage              // 2:1 equirectangular dome
        let environment: (() -> UIImage?)?
        let horizon: UIColor                // what the dome fades to at eye level; the fog takes it
        let fogNear: Float                  // where the fade starts, from the camera
        let fogFar: Float                   // and where it is complete
        let backdrop: (() -> UIImage?)?
        let ground: Ground?
        let skyline: Skyline?
        let sunEuler: SIMD3<Float>
        let light: LightLevels
        let grade: CameraGrade

        var lightLevels: LightLevels { light }
        var cameraGrade: CameraGrade { grade }
    }

    typealias LightLevels = StageSpec.LightLevels
    typealias CameraGrade = StageSpec.CameraGrade

    enum Stage {
        static let plaza = StageSpec(
            id: "plaza", name: "Daylight", icon: "sun.max.fill",
            sky: { CharacterSceneView.domeImage("sky_dome") ?? CharacterSceneView.skyBackdrop() },
            environment: nil,
            horizon: UIColor(red: CGFloat(CharacterSceneView.skyHorizon.0),
                             green: CGFloat(CharacterSceneView.skyHorizon.1),
                             blue: CGFloat(CharacterSceneView.skyHorizon.2), alpha: 1),
            fogNear: 3.0,
            fogFar: 22.0,
            backdrop: nil,
            ground: StageSpec.Ground(
                texture: { CharacterSceneController.plazaTexture },
                repeats: 55, extent: 60,
                inlay: { CharacterSceneController.plazaInlayTexture }, inlayExtent: 5,
                tint: nil),
            skyline: StageSpec.Skyline(
                texture: { CharacterSceneView.skylineTexture },
                radius: 13, band: 3.2, repeats: 4),
            sunEuler: SIMD3(-Float.pi / 3, Float.pi / 10, 0),
            light: LightLevels(key: 380, fill: 150, rim: 300, sun: 180, ibl: 0.25,
                               shadowAlpha: 0.45, rimShader: 0.04,
                               keyColor: UIColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1),
                               rimColor: .white),
            grade: CameraGrade(exposureOffset: 0.0, whitePoint: 1.0, contrast: 0.08,
                               vignetting: 0.22, bloom: 0.05, bloomThreshold: 1.1))

        static let sunset = StageSpec(
            id: "sunset", name: "Sunset", icon: "sunset.fill",
            sky: { CharacterSceneView.domeImage("sky_dome_sunset") ?? CharacterSceneView.skyBackdrop() },
            environment: nil,
            horizon: UIColor(red: 0.23, green: 0.14, blue: 0.14, alpha: 1),
            fogNear: 3.0,
            fogFar: 16.0,
            backdrop: nil,
            ground: StageSpec.Ground(
                texture: { CharacterSceneController.plazaTexture },
                repeats: 55, extent: 60,
                inlay: { CharacterSceneController.plazaInlayTexture }, inlayExtent: 5,
                tint: UIColor(red: 0.82, green: 0.52, blue: 0.38, alpha: 1)),
            skyline: nil,
            sunEuler: SIMD3(-0.20, Float.pi - 0.28, 0),
            light: LightLevels(key: 450, fill: 135, rim: 400, sun: 180, ibl: 0.24,
                               shadowAlpha: 0.32, rimShader: 0.07,
                               keyColor: UIColor(red: 1.0, green: 0.72, blue: 0.45, alpha: 1),
                               rimColor: UIColor(red: 1.0, green: 0.78, blue: 0.52, alpha: 1)),
            grade: CameraGrade(exposureOffset: 0.0, whitePoint: 1.05, contrast: 0.10,
                               vignetting: 0.28, bloom: 0.09, bloomThreshold: 1.0))

        static let all: [StageSpec] = [plaza, sunset]
        static func named(_ id: String?) -> StageSpec { all.first { $0.id == id } ?? plaza }
    }

    static let plazaTexture: UIImage = {
        let side: CGFloat = 512
        let n = 4
        let cell = side / CGFloat(n)
        let s = CGSize(width: side, height: side)

        var seed: UInt64 = 0x9E3779B9
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }

        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.545, green: 0.560, blue: 0.585, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: s))

            let inset: CGFloat = 5
            for row in 0..<n {
                for col in 0..<n {
                    let d = (rnd() - 0.5) * 0.14
                    let r = CGRect(x: CGFloat(col) * cell + inset, y: CGFloat(row) * cell + inset,
                                   width: cell - inset * 2, height: cell - inset * 2)
                    c.setFillColor(UIColor(red: 0.705 + d, green: 0.720 + d,
                                           blue: 0.740 + d, alpha: 1).cgColor)
                    c.fill(r)

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

            for _ in 0..<9000 {
                let x = rnd() * side, y = rnd() * side
                let w = 1 + rnd() * 1.6
                c.setFillColor(UIColor(white: rnd() < 0.5 ? 0 : 1, alpha: 0.045 + rnd() * 0.05).cgColor)
                c.fill(CGRect(x: x, y: y, width: w, height: w))
            }
        }
    }()

    static let plazaInlayTexture: UIImage = {
        let side: CGFloat = 512
        let s = CGSize(width: side, height: side)
        let mid = CGPoint(x: side / 2, y: side / 2)
        let rgb = CGColorSpaceCreateDeviceRGB()

        return UIGraphicsImageRenderer(size: s).image { ctx in
            let c = ctx.cgContext
            c.clear(CGRect(origin: .zero, size: s))

            func stone(_ v: CGFloat, _ a: CGFloat) -> CGColor {
                UIColor(red: 0.705 * v, green: 0.720 * v, blue: 0.740 * v, alpha: a).cgColor
            }

            let body = CGGradient(colorsSpace: rgb,
                                  colors: [stone(0.86, 0.45), stone(0.95, 0.45),
                                           stone(1.10, 0.55), stone(1.10, 0)] as CFArray,
                                  locations: [0, 0.55, 0.955, 1])!
            c.drawRadialGradient(body, startCenter: mid, startRadius: 0,
                                 endCenter: mid, endRadius: side / 2, options: [])

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

    @Published var stage: StageSpec = Stage.plaza {
        didSet {
            guard oldValue != stage else { return }
            updateBackgroundAndGround()
        }
    }

    var isToonCharacter = false

    private static let toonAlbedoScale: CGFloat = 0.68

    private static let rimLightModifier = """
    #pragma arguments
    float rimStrength;
    #pragma body
    float3 normal = normalize(_surface.normal);
    float3 view = normalize(_surface.view);
    float rim = pow(1.0 - saturate(dot(normal, view)), 4.0);
    float3 rimColor = float3(0.7, 0.8, 1.0);
    _output.color.rgb += rim * rimColor * (rimStrength * _output.color.a);
    """

    private func sanitizeMaterials(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .physicallyBased
                material.isDoubleSided = true

                // Exported self-lighting and metallic skin wash out the original texture.
                material.emission.contents = UIColor.black
                material.emission.intensity = 0
                material.selfIllumination.contents = UIColor.black
                material.selfIllumination.intensity = 0
                material.metalness.contents = NSNumber(value: 0)
                material.metalness.intensity = 1

                // Keep authored roughness textures, while limiting mirror-like scalar values.
                if let roughness = material.roughness.contents as? NSNumber {
                    material.roughness.contents = NSNumber(value: max(roughness.doubleValue, 0.45))
                }
                material.roughness.intensity = 1

                if isToonCharacter {
                    material.multiply.contents = UIColor(white: Self.toonAlbedoScale, alpha: 1)
                }

                // Imported VRM materials may already discard transparent pixels in a fragment
                // modifier. Preserve that shader instead of replacing it with our rim effect.
                var modifiers = material.shaderModifiers ?? [:]
                if modifiers[.fragment] == nil {
                    modifiers[.fragment] = Self.rimLightModifier
                }
                material.shaderModifiers = modifiers
                material.setValue(lightLevels.rimShader, forKey: "rimStrength")
            }
        }
    }

    private func worldBoundingHeight(_ root: SCNNode) -> Float {
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] {
                for y in [Float(a.y), Float(b.y)] {
                    for z in [Float(a.z), Float(b.z)] {
                        let w = node.simdConvertPosition(simd_float3(x, y, z), to: nil)
                        minY = min(minY, w.y)
                        maxY = max(maxY, w.y)
                    }
                }
            }
        }
        return maxY.isFinite && minY.isFinite ? max(maxY - minY, 0) : 0
    }

    private func normalizeOrientation(_ root: SCNNode) {
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let lsh = boneNodes[scheme.leftShoulder]?.simdWorldPosition,
              let rsh = boneNodes[scheme.rightShoulder]?.simdWorldPosition else { return }
        let up = simd_normalize(head - hips)
        let right0 = simd_normalize(lsh - rsh)
        let forward = simd_normalize(simd_cross(right0, up))
        let right = simd_normalize(simd_cross(up, forward))
        let m = simd_float3x3(right, up, forward)
        root.simdOrientation = simd_quatf(m).inverse
    }

    private func addLights() {
        environmentManager.setupLights(lightsAdded: &lightsAdded, characterRoot: characterRoot)
    }

    var lightLevels: StageSpec.LightLevels { stage.lightLevels }

    func applyLightLevels() {
        environmentManager.applyLightLevels(stage: stage, lightLevels: lightLevels, characterRoot: characterRoot)
    }

    var cameraGrade: StageSpec.CameraGrade { stage.cameraGrade }

    func applyCameraGrade() {
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

        if DeviceTier.allowsCinematicEffects {
            camera.motionBlurIntensity = 0.5
            camera.fStop = 2.8
            camera.focalBlurSampleCount = 8
        } else {
            camera.motionBlurIntensity = 0
            camera.fStop = 0
        }
    }

    func updateBackgroundAndGround() {
        environmentManager.updateBackgroundAndGround(
            stage: stage,
            groundEnabled: groundEnabled,
            contactShadowOnly: contactShadowOnly,
            modelHeight: modelHeight,
            characterRoot: characterRoot,
            cameraNode: cameraNode,
            viewportAspect: viewportAspect,
            humanoidNode: { [weak self] in self?.humanoidNode($0) },
            syncCameraControl: { [weak self] in self?.syncCameraControl() },
            applyCameraGrade: { [weak self] in self?.applyCameraGrade() }
        )
    }

    func setRimTint(_ color: UIColor?) {
        environmentManager.setRimTint(color, stage: stage)
    }

    var feetY: Float { environmentManager.feetY }

    var groundY: Float? {
        guard isLoaded else { return nil }
        if let ar = arGroundY { return ar }
        return (groundEnabled || contactShadowOnly) ? feetY : nil
    }

    /// Set by `ARCharacterView` when the character is placed in AR.
    var arGroundY: Float?

    var stageCenter: simd_float3 { environmentManager.stageCenter }

    var isAutoOrbiting: Bool {
        get { cameraController.isAutoOrbiting }
        set { cameraController.isAutoOrbiting = newValue }
    }

    var viewportAspect: Float {
        get { cameraController.viewportAspect }
        set { cameraController.viewportAspect = newValue }
    }

    weak var hostView: SCNView? {
        get { cameraController.hostView }
        set { cameraController.hostView = newValue }
    }

    weak var cameraPan: UIPanGestureRecognizer? {
        get { cameraController.cameraPan }
        set { cameraController.cameraPan = newValue }
    }

    var usesFlatBackdrop: Bool { stage.backdrop != nil }

    func dragCamera(byX dx: Float, y dy: Float) {
        cameraController.dragCamera(byX: dx, y: dy)
    }

    func resetCameraDrag() {
        cameraController.resetCameraDrag()
    }

    func syncCameraControl() {
        cameraController.syncCameraControl(cameraNode: cameraNode, stageBackdrop: stage.backdrop)
    }

    func startAutoOrbit() { cameraController.startAutoOrbit() }
    func stopAutoOrbit() { cameraController.stopAutoOrbit() }
    func resetCameraMove() { cameraController.resetCameraMove() }

    func stepCameraMove() {
        cameraController.stepCameraMove(
            cameraNode: cameraNode,
            modelHeight: modelHeight,
            stageCenter: stageCenter,
            feetY: feetY,
            posedBounds: { [weak self] in self?.posedBounds() },
            distanceForHalfExtent: { [weak self] half, aspect, margin, fov in
                self?.distance(forHalfExtent: half, aspect: aspect, margin: margin, fieldOfView: fov) ?? 0
            }
        )
    }

    func fitBackdrop() {
        environmentManager.fitBackdrop(
            cameraNode: cameraNode,
            viewportAspect: viewportAspect,
            modelHeight: modelHeight,
            stage: stage,
            groundEnabled: groundEnabled
        )
    }

    func distance(forHalfExtent half: simd_float3, aspect: Float, margin: Float, fieldOfView: CGFloat) -> Float {
        let fov = Float(fieldOfView) * .pi / 180
        let verticalHalfFOV = fov * 0.5
        let horizontalHalfFOV = atan(tan(verticalHalfFOV) * aspect)
        let dVert = half.y / tan(verticalHalfFOV)
        let dHoriz = half.x / tan(horizontalHalfFOV)
        let dDepth = half.z
        return (max(dVert, dHoriz) + dDepth) * margin
    }

    func placeCamera(center: simd_float3, distance: Float, fieldOfView: CGFloat) {
        guard let cam = cameraNode, let camera = cam.camera else { return }
        camera.projectionDirection = .vertical
        camera.fieldOfView = fieldOfView
        cam.simdPosition = simd_float3(center.x, center.y, center.z + distance)
        cam.look(at: SCNVector3(center))
        camera.zNear = Double(max(distance * 0.01, 0.001))
        camera.zFar = Double(distance * 4 + modelHeight * 10)
    }

    func frameCameraOnPose(aspect: Float, margin: Float = 1.12, fieldOfView: CGFloat = 42) {
        guard let bounds = posedBounds() else { return }
        frameCamera(
            on: bounds,
            aspect: aspect,
            margin: margin,
            fieldOfView: fieldOfView
        )
    }

    /// Also accepts the combined bounds of a take, so every sampled pose stays in frame.
    func frameCamera(
        on bounds: (min: simd_float3, max: simd_float3),
        aspect: Float,
        margin: Float = 1.1,
        fieldOfView: CGFloat = 42
    ) {
        let center = (bounds.min + bounds.max) * 0.5
        let halfExtent = (bounds.max - bounds.min) * 0.5
        let cameraDistance = distance(
            forHalfExtent: halfExtent,
            aspect: aspect,
            margin: margin,
            fieldOfView: fieldOfView
        )
        placeCamera(
            center: center,
            distance: cameraDistance,
            fieldOfView: fieldOfView
        )
    }

    func beginCameraFollow(aspect: Float, margin: Float = 1.12, fieldOfView: CGFloat = 42) {
        cameraController.beginCameraFollow(
            aspect: aspect,
            margin: margin,
            fieldOfView: fieldOfView,
            posedBounds: { [weak self] in self?.posedBounds() },
            distanceForHalfExtent: { [weak self] half, aspect, margin, fov in
                self?.distance(forHalfExtent: half, aspect: aspect, margin: margin, fieldOfView: fov) ?? 0
            },
            placeCamera: { [weak self] center, dist, fov in
                self?.placeCamera(center: center, distance: dist, fieldOfView: fov)
            }
        )
    }

    func endCameraFollow() {
        cameraController.endCameraFollow()
    }

    func stepCameraFollow() {
        cameraController.stepCameraFollow(
            posedBounds: { [weak self] in self?.posedBounds() },
            distanceForHalfExtent: { [weak self] half, aspect, margin, fov in
                self?.distance(forHalfExtent: half, aspect: aspect, margin: margin, fieldOfView: fov) ?? 0
            },
            placeCamera: { [weak self] center, dist, fov in
                self?.placeCamera(center: center, distance: dist, fieldOfView: fov)
            }
        )
    }

    func setupFrontCamera() {
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let foot = boneNodes[scheme.leftFoot]?.simdWorldPosition else { return }
        let height = abs(head.y - foot.y)
        guard height > 0 else { return }
        modelHeight = height
        let center = SCNVector3(hips.x, (head.y + foot.y) / 2, hips.z)

        let cam = cameraNode ?? {
            let n = SCNNode(); n.camera = SCNCamera()
            scene.rootNode.addChildNode(n); cameraNode = n; return n
        }()

        if let camera = cam.camera {
            camera.zNear = Double(height) * 0.01
            camera.zFar = Double(height) * 50
            if !DeviceTier.isLowEnd {
                camera.screenSpaceAmbientOcclusionIntensity = groundEnabled ? 0.4 : 0.2
                camera.screenSpaceAmbientOcclusionRadius = 1.0
            }
        }
        if groundEnabled {
            cam.camera?.fieldOfView = 55
            cam.position = SCNVector3(center.x, foot.y + height * 1.05, center.z + height * 2.25)
            cam.look(at: SCNVector3(center.x, foot.y + height * 0.48, center.z))
        } else {
            cam.camera?.fieldOfView = 62
            cam.position = SCNVector3(center.x, center.y, center.z + height * 1.9)
            cam.look(at: center)
        }
    }

    func posedBounds() -> (min: simd_float3, max: simd_float3)? {
        guard !boundsNodes.isEmpty else { return nil }
        var minPos = simd_float3(repeating: Float.greatestFiniteMagnitude)
        var maxPos = simd_float3(repeating: -Float.greatestFiniteMagnitude)
        for node in boundsNodes {
            let p = node.simdWorldPosition
            minPos = min(minPos, p)
            maxPos = max(maxPos, p)
        }
        return (minPos, maxPos)
    }
}

// MARK: - SwiftUI View & Coordinator

struct CharacterSceneView: UIViewRepresentable {
    let controller: CharacterSceneController
    var onAttach: (() -> Void)? = nil
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
            controller.fitBackdrop()
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            guard !firstFrameDelivered else { return }
            firstFrameDelivered = true
            let cb = onFirstFrame
            onFirstFrame = nil
            DispatchQueue.main.async { cb?() }
        }

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

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard g.state == .changed else { return }
            let t = g.translation(in: g.view)
            controller.dragCamera(byX: Float(t.x), y: Float(t.y))
            g.setTranslation(.zero, in: g.view)
        }
    }

    func makeUIView(context: Context) -> SCNView {
        controller.reattachToScreenScene()
        onAttach?()
        let view = SCNView()
        view.scene = controller.scene
        view.antialiasingMode = DeviceTier.antialiasing
        view.preferredFramesPerSecond = 60

        if UIDevice.current.userInterfaceIdiom == .pad {
            view.contentScaleFactor = min(view.contentScaleFactor, 2.0)
        }

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        let rotate = UIRotationGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleRotate(_:)))
        view.addGestureRecognizer(rotate)
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        controller.hostView = view
        controller.cameraPan = pan

        let cc = view.defaultCameraController
        cc.interactionMode = .orbitTurntable
        cc.inertiaEnabled = true
        cc.minimumVerticalAngle = -6
        cc.maximumVerticalAngle = 55
        cc.target = SCNVector3(0, controller.feetY + controller.modelHeight * 0.5, 0)
        controller.updateBackgroundAndGround()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        context.coordinator.onFirstFrame = onFirstFrame
        view.delegate = context.coordinator
        view.rendersContinuously = true
        view.isPlaying = true
        view.preferredFramesPerSecond = DeviceTier.playbackFPS
        if let cam = controller.cameraNode { view.pointOfView = cam }
        controller.syncCameraControl()
        holder?.scnView = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        controller.hostView = uiView
        controller.syncCameraControl()
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        uiView.delegate = nil
        uiView.scene = nil
        uiView.pointOfView = nil
    }

    static let skyImage: UIImage = makeSkyBackdrop()
    static func skyBackdrop() -> UIImage { skyImage }

    static func domeImage(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else {
            NSLog("[Stage] %@.jpg is not in the bundle", name)
            return nil
        }
        return UIImage(contentsOfFile: url.path)
    }

    static let studioEnvironment: UIImage = {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor)
            c.fill(CGRect(origin: .zero, size: size))

            let topGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [UIColor.white.withAlphaComponent(0.3).cgColor, UIColor.clear.cgColor] as CFArray,
                                    locations: [0, 1])!
            c.drawLinearGradient(topGrad, start: .zero, end: CGPoint(x: 0, y: size.height * 0.4), options: [])

            c.setShadow(offset: .zero, blur: 20, color: UIColor.white.cgColor)
            c.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            c.fill(CGRect(x: 40, y: 40, width: 20, height: 180))
            c.fill(CGRect(x: 450, y: 40, width: 20, height: 180))

            let bottomGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                       colors: [UIColor(red: 0.2, green: 0.15, blue: 0.3, alpha: 1).cgColor, UIColor.clear.cgColor] as CFArray,
                                       locations: [0, 1])!
            c.drawLinearGradient(bottomGrad, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: size.height * 0.7), options: [])
        }
    }()

    static let skyHorizon: (Double, Double, Double) = (0.65, 0.74, 0.78)

    static let skylineTexture: UIImage = {
        let w = 2048, h = 256
        let size = CGSize(width: w, height: h)
        let hz = skyHorizon

        var seed: UInt64 = 0x5C0FFEE
        func rnd() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 100_000) / 100_000
        }

        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.clear(CGRect(origin: .zero, size: size))

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
                    if rnd() < 0.3 {
                        let iw = bw * (0.24 + rnd() * 0.3)
                        p.addRect(CGRect(x: rect.midX - iw / 2, y: rect.minY - 10 - rnd() * 30,
                                         width: iw, height: 24))
                    }
                    fill(p, tint: tint)
                    x += bw + (far ? 3 : 6) + rnd() * (far ? 20 : 40)
                }
            }

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
