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
            scene.background.contents = CharacterSceneView.studioBackdrop()
            fog = UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1)   // = Background color, seamless at horizon
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
            scene.fogStartDistance = CGFloat(h * 2.2)
            scene.fogEndDistance = CGFloat(h * 6.5)
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
    private(set) var feetY: Float = 0   // World Y of feet (for VFX ground positioning)

    /// Ground: Visible floor (with slight reflection) + a soft contact shadow always visible under feet to eliminate "floating" sensation.
    private func setupGround(_ root: SCNNode) {
        guard groundEnabled || contactShadowOnly else {
            floorNode?.removeFromParentNode(); floorNode = nil
            contactShadow?.removeFromParentNode(); contactShadow = nil
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

        // Floor: Slightly brighter than background color + slight reflection, forming a clear "ground" reference
        floorNode?.removeFromParentNode()
        let floor = SCNFloor()
        if backgroundType == .sky {
            // Sky mode: Keep only reflections; material is completely transparent and doesn't capture lighting, avoiding a white layer
            floor.reflectivity = DeviceTier.skyFloorReflectivity
            floor.firstMaterial?.diffuse.contents = UIColor.clear
            floor.firstMaterial?.lightingModel = .constant
        } else {
            // Restore original stage mode: Dark reflective floor (disable reflection on low-end devices — reflection means rendering the entire scene again)
            floor.reflectivity = DeviceTier.floorReflectivity
            floor.firstMaterial?.diffuse.contents = UIColor(red: 0.13, green: 0.13, blue: 0.18, alpha: 1)
            floor.firstMaterial?.lightingModel = .physicallyBased
        }
        floor.firstMaterial?.roughness.contents = 0.82
        let node = SCNNode(geometry: floor)
        node.simdPosition = simd_float3(0, minY, 0)
        scene.rootNode.addChildNode(node)
        floorNode = node

        // Soft contact shadow under feet (always visible, provides "grounding" cues even if directional light shadows aren't rendered)
        contactShadow?.removeFromParentNode()
        let blob = SCNPlane(width: CGFloat(footSpan * 2.4), height: CGFloat(footSpan * 1.5))
        let bm = blob.firstMaterial!
        bm.diffuse.contents = Self.contactShadowTexture
        bm.lightingModel = .constant
        bm.isDoubleSided = true
        bm.writesToDepthBuffer = false
        let bnode = SCNNode(geometry: blob)
        bnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)          // Tiled on the ground
        bnode.simdPosition = simd_float3(cx, minY + 0.003, cz)
        bnode.renderingOrder = 1                                     // Drawn above the floor
        scene.rootNode.addChildNode(bnode)
        contactShadow = bnode
    }

    /// Soft circular contact shadow map: black center, transparent edges. Fixed content -> generated only once.
    private static let contactShadowTexture: UIImage = makeContactShadowImage()

    private static func makeContactShadowImage() -> UIImage {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0).cgColor]
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
        if groundEnabled {
            // Large performance view: Slightly top-down, making the floor and shadows visible, as if standing on the ground
            cam.camera?.fieldOfView = 60
            cam.position = SCNVector3(center.x, foot.y + height * 1.05, center.z + height * 2.15)
            cam.look(at: SCNVector3(center.x, foot.y + height * 0.5, center.z))
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
        key.position = SCNVector3(0, 100, 100)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        // Directional light from the front-top, casting realistic soft shadows that change with movement.
        // forward soft shadows are expensive (one shadow pass per frame + multiple samples), disabled on low-end devices —
        // the contact shadow map under the feet provides enough "grounding" cues.
        let sun = SCNNode()
        let l = SCNLight(); l.type = .directional
        l.castsShadow = DeviceTier.dynamicShadows
        l.shadowMode = .forward            // Universally reliable (including the Simulator), and the shadow is visible on the floor
        l.shadowColor = UIColor(white: 0, alpha: 0.5)
        l.shadowRadius = 6
        l.shadowSampleCount = DeviceTier.shadowSampleCount
        sun.light = l
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
        view.autoenablesDefaultLighting = true
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

    private static func makeStudioBackdrop() -> UIImage {
        let size = CGSize(width: 300, height: 650)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // Vertical gradient: Cold purple at top -> Dark color at bottom (=fogColor 0.06, 0.06, 0.10, seamless with fog/ground)
            let colors = [UIColor(red: 0.17, green: 0.15, blue: 0.28, alpha: 1).cgColor,
                          UIColor(red: 0.11, green: 0.10, blue: 0.17, alpha: 1).cgColor,
                          UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.5, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // Horizon glow: Warm purple soft light in the mid-bottom, like a spotlight on the back stage wall, adding depth
            let halo = [UIColor(red: 0.42, green: 0.33, blue: 0.7, alpha: 0.38).cgColor, UIColor.clear.cgColor]
            let hg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: halo as CFArray, locations: [0, 1])!
            c.drawRadialGradient(hg,
                                 startCenter: CGPoint(x: size.width/2, y: size.height*0.64), startRadius: 0,
                                 endCenter: CGPoint(x: size.width/2, y: size.height*0.64), endRadius: size.width*0.85,
                                 options: [])
            // Soft light circle at bottom center, like a spotlight at feet
            let glow = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
            let rg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow as CFArray, locations: [0, 1])!
            c.drawRadialGradient(rg,
                                 startCenter: CGPoint(x: size.width/2, y: size.height*0.78), startRadius: 0,
                                 endCenter: CGPoint(x: size.width/2, y: size.height*0.78), endRadius: size.width*0.7,
                                 options: [])
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
