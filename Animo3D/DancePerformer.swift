//
//  DancePerformer.swift
//  Animo3D
//
//  The one place a character is loaded and a dance is driven onto its skeleton.
//
//  There were four copies of this before: the stage (DanceStage), the selected dance card
//  (LiveDanceView), the enlarged preview (PreviewStage) and the thumbnail renderer each loaded a
//  model, built their own PoseRetargeter and started their own MocapPlayer. They had drifted apart
//  in every detail that matters - one parsed on the main thread, one forgot `warmUp`, one assumed
//  every model was a `.scn`, one leaked its display link on dismiss - and a fix applied to one of
//  them stayed broken in the other three. Everything that performs a dance goes through here now.
//
//  Loading is deliberately two-phase: the model (4-60MB) and the clip (~600KB) are parsed on a
//  background task and only node mounting happens on the main thread. Doing the parse inline is
//  what used to freeze the screen when entering the stage and on every character switch.
//

import SwiftUI
import SceneKit
import Combine
import simd

#if canImport(VRMKit)
import VRMKit
#endif
#if canImport(VRMSceneKit)
import VRMSceneKit
#endif

@MainActor
final class DancePerformer: ObservableObject {
    let controller = CharacterSceneController()

    /// True once the character is mounted and the scene is worth showing.
    @Published private(set) var isReady = false

    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var loadedCharacter = ""
    private var loadedDance = ""

    /// The model parsed ahead of time, keyed by the character it belongs to.
    private var prewarmKey = ""
    private var prewarmTask: Task<SCNScene?, Never>?

    var isAnimating: Bool { player != nil }

    /// Who owns this performer, for logs only.
    private let owner: String

    init(owner: String = "?", groundEnabled: Bool = false, contactShadowOnly: Bool = false) {
        self.owner = owner
        controller.groundEnabled = groundEnabled
        controller.contactShadowOnly = contactShadowOnly
        NSLog("[Performer] %@ created", owner)
    }

    deinit { NSLog("[Performer] %@ released", owner) }

    // MARK: - Prewarm

    /// Start parsing a character's model in the background. Cheap to call repeatedly.
    ///
    /// Without this the same file is parsed again on "Start Performance" after the grid already
    /// parsed it, and `SCNScene(url:)` plus `warmUp` on a 60MB model is seconds of work each time.
    func prewarm(character: String) {
        guard !character.isEmpty, character != prewarmKey else { return }
        prewarmKey = character
        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) {
            guard let url = try? await RemoteAssets.shared.resolveCharacterModel(character) else { return nil }
            guard !Task.isCancelled else { return nil }
            return CharacterSceneController.loadSceneFile(at: url, warmUp: true)
        }
    }

    /// Pull down the full take. The dance grid only ever needs the pre-rendered card art, so the
    /// clip itself is still missing at the moment the user presses Start.
    func prewarm(dance: String) {
        guard !dance.isEmpty, let path = RemoteAssets.shared.dance(dance)?.clip else { return }
        Task.detached(priority: .utility) { _ = try? await RemoteAssets.shared.resolve(path) }
    }

    // MARK: - Load

    /// Mount `character` and, when a dance is given, start driving it.
    ///
    /// Returns false when the scene could not be assembled, so the caller can drop its loading mask
    /// instead of leaving it up forever.
    @discardableResult
    func load(character: String, dance: String? = nil) async -> Bool {
        guard !character.isEmpty else { return false }
        stop()

        if character != loadedCharacter || !controller.isLoaded {
            guard let scene = await scene(for: character) else { return false }
            // A parsed scene can only be installed once - install() reparents its root node - so
            // the prewarmed copy is consumed here rather than left for a second Start.
            controller.install(scene)
            guard controller.isLoaded else {
                NSLog("[Performer] model %@ mounted with no skeleton", character)
                return false
            }
            loadedCharacter = character
        }
        // The retargeter is built whether or not there is a clip: the video-drive screen feeds it
        // MediaPipe landmarks instead of a stored take, and that used to be a fifth private copy
        // of this same setup.
        let rt = PoseRetargeter(controller: controller)
        rt.resetCapture()
        retargeter = rt
        isReady = true
        loadedDance = ""

        guard let dance, !dance.isEmpty else { return true }
        guard let clip = await clip(for: dance) else { return false }
        player = MocapPlayer(clip: clip, retargeter: rt)
        player?.start()
        loadedDance = dance
        NSLog("[Performer] %@: %@ performing %@ (%d frames)", owner, character, dance, clip.frames.count)
        return true
    }

    private func scene(for character: String) async -> SCNScene? {
        if prewarmKey == character, let task = prewarmTask {
            prewarmKey = ""
            prewarmTask = nil
            if let scene = await task.value { return scene }
        }
        prewarmKey = ""
        prewarmTask = nil
        guard let url = try? await RemoteAssets.shared.resolveCharacterModel(character) else {
            NSLog("[Performer] failed to download/locate model for %@", character)
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(at: url, warmUp: true)
        }.value
    }

    private func clip(for dance: String) async -> MocapClip? {
        guard let path = RemoteAssets.shared.dance(dance)?.clip else {
            NSLog("[Performer] %@ is not in the catalog", dance)
            return nil
        }
        guard let url = try? await RemoteAssets.shared.resolve(path) else {
            NSLog("[Performer] failed to download/locate clip %@", path)
            return nil
        }
        guard let clip = await Task.detached(priority: .userInitiated, operation: { MocapClip.load(url) }).value else {
            // Whatever is cached under that name does not parse. Drop it so the next attempt
            // re-downloads instead of failing identically on every launch.
            RemoteAssets.shared.evict(path)
            return nil
        }
        return clip
    }

    // MARK: - Control

    /// Re-sample the static pose after the character is re-mounted (screen <-> AR).
    /// Re-establish the retargeter's reference pose at the character's *current* place in the world.
    ///
    /// Two things have to happen together, and neither works alone:
    ///
    /// - **The skeleton goes back to its bind pose first.** `resetCapture()` re-samples the rest
    ///   reference on the next frame from whatever the bones happen to look like then - and
    ///   mid-dance that is a dancing pose, not a rest pose. Every subsequent frame is then measured
    ///   against a crouch or a lunge, and the character drifts further from the take each time it
    ///   is re-based. `resetToRestPose()` has carried that warning in its doc comment since it was
    ///   written; it had simply never been called.
    /// - **It has to run after the character is placed, not before.** The retargeter pins the hips
    ///   to `charHipsRestWorld + delta`, an absolute world position captured with the rest pose. In
    ///   AR that capture used to happen on attach, while the character was still hidden in front of
    ///   the camera - so once it was anchored to a floor, every frame dragged the skeleton back to
    ///   the pre-placement spot. The container sat on the anchor; the body did not.
    func rebaseRetarget() {
        controller.resetToRestPose()
        retargeter?.resetCapture()
    }

    /// Drive the skeleton from live pose landmarks (camera or video source).
    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }

    /// Update a VRM blendshape weight (0.0 - 1.0)
    func setBlendShape(value: Float, for preset: String) {
        #if canImport(VRMKit) && canImport(VRMSceneKit)
        guard let vrm = controller.characterRoot as? VRMNode else { return }

        var applied = false
        // 优先使用库的 ExpressionRuntime 设置
        if let info = vrm.availableExpressions.first(where: { $0.name == preset }) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0
            vrm.setExpression(value: CGFloat(value), for: info.key)
            SCNTransaction.commit()
            applied = true
        }

        // 保底逻辑：如果上面的方法没生效，直接驱动底层的 SCNMorpher
        controller.characterRoot?.enumerateHierarchy { node, _ in
            if let morpher = node.morpher {
                for i in 0..<morpher.targets.count {
                    let targetName = morpher.targets[i].name ?? "Morph-\(i)"
                    if targetName == preset || targetName.lowercased().contains(preset.lowercased()) {
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0
                        morpher.setWeight(CGFloat(value), forTargetAt: i)
                        SCNTransaction.commit()
                        applied = true
                    }
                }
            }
        }

        if applied {
            vrm.update(at: CACurrentMediaTime())
        }
        #endif
    }

    /// 获取当前模型支持的所有表情名称 (VRM 预设 + 底层 Morpher 目标)
    func getAvailableVRMExpressions() -> [String] {
        #if canImport(VRMKit) && canImport(VRMSceneKit)
        guard let vrm = controller.characterRoot as? VRMNode else { return [] }

        // 1. 尝试获取 VRM 标准定义的表情
        let vrmNames = vrm.availableExpressions.map { $0.name }
        if !vrmNames.isEmpty { return vrmNames }

        // 2. 如果没有 VRM 定义，则扫描底层 SCNMorpher 的所有 Target 名称
        var rawNames = Set<String>()
        controller.characterRoot?.enumerateHierarchy { node, _ in
            if let morpher = node.morpher {
                for i in 0..<morpher.targets.count {
                    if let name = morpher.targets[i].name, !name.isEmpty {
                        rawNames.insert(name)
                    } else {
                        // 如果目标没有名字，至少给个索引
                        rawNames.insert("Morph-\(i)")
                    }
                }
            }
        }
        return Array(rawNames).sorted()
        #else
        return []
        #endif
    }

    #if canImport(VRMKit) && canImport(VRMSceneKit)
    private func vrm_expression_for(_ name: String) -> ExpressionKey? {
        switch name.lowercased() {
        case "a": return .preset(.aa)
        case "i": return .preset(.ih)
        case "u": return .preset(.ou)
        case "e": return .preset(.ee)
        case "o": return .preset(.oh)
        case "joy": return .preset(.happy)
        case "angry": return .preset(.angry)
        case "sorrow": return .preset(.sad)
        case "fun": return .preset(.relaxed)
        case "blink": return .preset(.blink)
        case "lookup": return .preset(.lookUp)
        case "lookdown": return .preset(.lookDown)
        default: return nil
        }
    }
    #endif

    /// Always call this when the view goes away: `CADisplayLink(target:)` retains its target, so a
    /// player left running keeps burning CPU after the page is dismissed.
    func stop() {
        player?.stop()
        player = nil
        loadedDance = ""
    }

    // MARK: - Test Support

    /// Load a character and a dance from local URLs, bypassing the catalog.
    func loadLocal(modelURL: URL, danceURL: URL? = nil, isVRM: Bool = false) async -> Bool {
        stop()

        var loadedScene: SCNScene?
        var vrmNode: SCNNode?

        if isVRM {
            #if canImport(VRMKit) && canImport(VRMSceneKit)
            do {
                let loader = try VRMSceneLoader(withURL: modelURL)
                let scene = try loader.loadScene()
                loadedScene = scene
                vrmNode = scene.vrmNode
            } catch {
                NSLog("[Performer] VRMKit load failed: %@", error.localizedDescription)
                return false
            }
            #else
            NSLog("[Performer] VRMKit/VRMSceneKit not found, falling back to SceneKit")
            loadedScene = CharacterSceneController.loadSceneFile(at: modelURL, warmUp: true)
            #endif
        } else {
            loadedScene = CharacterSceneController.loadSceneFile(at: modelURL, warmUp: true)
        }

        guard let scene = loadedScene else { return false }
        controller.install(scene)

        // VRM Bone Mapping: Map VRM humanoid bones to the names expected by the Mixamo scheme.
        // This allows setupFrontCamera() and normalizeOrientation() to find the character's head, feet, etc.
        #if canImport(VRMKit) && canImport(VRMSceneKit)
        if isVRM, let vrm = vrmNode as? VRMNode {
            let mapping: [HumanoidBone: String] = [
                .hips: "mixamorig_Hips",
                .spine: "mixamorig_Spine",
                .head: "mixamorig_Head",
                .leftShoulder: "mixamorig_LeftShoulder",
                .rightShoulder: "mixamorig_RightShoulder",
                .leftUpperArm: "mixamorig_LeftArm",
                .rightUpperArm: "mixamorig_RightArm",
                .leftLowerArm: "mixamorig_LeftForeArm",
                .rightLowerArm: "mixamorig_RightForeArm",
                .leftHand: "mixamorig_LeftHand",
                .rightHand: "mixamorig_RightHand",
                .leftUpperLeg: "mixamorig_LeftUpLeg",
                .rightUpperLeg: "mixamorig_RightUpLeg",
                .leftLowerLeg: "mixamorig_LeftLeg",
                .rightLowerLeg: "mixamorig_RightLeg",
                .leftFoot: "mixamorig_LeftFoot",
                .rightFoot: "mixamorig_RightFoot",
                .leftToes: "mixamorig_LeftToeBase",
                .rightToes: "mixamorig_RightToeBase"
            ]

            var mappedCount = 0
            for (bone, mixamoName) in mapping {
                if let node = vrm.humanoid.node(for: bone) {
                    controller.boneNodes[mixamoName] = node
                    mappedCount += 1
                }
            }
            NSLog("[Performer] VRM mapping complete: %d bones mapped", mappedCount)

            // Re-run setup now that bones are mapped
            if let root = controller.characterRoot {
                controller.sanitizeMaterials(root)
                controller.normalizeOrientation(root)
                controller.setupFrontCamera()
                controller.updateBackgroundAndGround()
                controller.captureBindPose()

                // 开启表情逻辑 (修正后的 0.10.0 API)
                vrm.setExpression(value: 0.8, for: .preset(.happy))
                vrm.setExpression(value: 0.2, for: .preset(.blink))

                // If it's still not visible, it might be a scale issue. VRM is meters, but some are cm.
                if controller.modelHeight < 0.1 {
                    NSLog("[Performer] Model seems too small (%.2fm), applying 100x scale", controller.modelHeight)
                    root.simdScale = simd_float3(repeating: 100)
                    controller.setupFrontCamera() // Recalculate camera for new scale
                }
            }
        }
        #endif

        guard controller.isLoaded else { return false }

        loadedCharacter = "local"
        let rt = PoseRetargeter(controller: controller)
        rt.resetCapture()
        retargeter = rt
        isReady = true

        if let danceURL, let clip = MocapClip.load(danceURL) {
            player = MocapPlayer(clip: clip, retargeter: rt)
            player?.start()
            loadedDance = "local"
            NSLog("[Performer] local performance started")
        }

        return true
    }
}
