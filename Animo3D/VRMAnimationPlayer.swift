//
//  VRMAnimationPlayer.swift
//  Animo3D
//
//  Plays a `VRMAnimationClip` onto a loaded model's humanoid bones.
//
//  The player knows nothing about VRMKit: it is handed a bone lookup and, optionally, something to
//  tick once a frame (spring bones). That keeps the retarget testable against any skeleton whose
//  bones can be named the way the VRM humanoid names them.
//

import Foundation
import SceneKit
import simd
import QuartzCore

@MainActor
final class VRMAnimationPlayer {

    /// One source bone's contribution, as the world-space rotation it adds to its parent's, with
    /// the VRM 0.x facing flip folded into both ends. Identity while the take rests.
    private struct Delta {
        let track: VRMAnimationClip.RotationTrack
        let pre: simd_quatf
        let post: simd_quatf

        func value(at time: Float) -> simd_quatf { pre * track.value(at: time) * post }
    }

    private struct Binding {
        let node: SCNNode
        /// The source deltas from the nearest ancestor the model also has down to this bone, root
        /// first, so a bone the model lacks still passes its rotation to the bones below it.
        let deltas: [Delta]
        /// inverse(target parent rest rotation), in model space.
        let pre: simd_quatf
        /// target rest rotation, in model space.
        let post: simd_quatf
        /// Hips only. The take's translation is not used as an absolute position: it is measured
        /// from a reference and added to where the model's own hips rest, so the character dances
        /// where it was put instead of teleporting to wherever the take's rig stood.
        let translation: Hips?

        func rotation(at time: Float) -> simd_quatf {
            deltas.reduce(pre) { $0 * $1.value(at: time) } * post
        }
    }

    /// How the hips follow the take: source translation -> target parent space, less a reference,
    /// plus the model's own rest position.
    private struct Hips {
        let track: VRMAnimationClip.VectorTrack
        let transform: simd_float4x4
        /// Subtracted from every mapped sample. Horizontally it is the take's opening frame, so the
        /// character starts where it stands; vertically it is the take's *lowest* hip, so a take
        /// that never returns to its rest height does not leave the character sunk for its whole
        /// length. `PoseRetargeter` splits the reference the same way, for the same reason.
        let reference: simd_float3
        /// The model's hips, in its own bind pose.
        let rest: simd_float3

        func position(at time: Float) -> simd_float3 {
            let mapped = transform * simd_float4(track.value(at: time), 1)
            return rest + simd_float3(mapped.x, mapped.y, mapped.z) - reference
        }
    }

    private let clip: VRMAnimationClip
    private let bindings: [Binding]
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    // MARK: Foot planting
    //
    // A retargeted take does not know how long the model's legs are, so a squat that grounded the
    // source rig leaves this one hovering, and a long-legged model drives its boots through the
    // floor. Both are corrected the way `PoseRetargeter` corrects them - the algorithm below is
    // that one, and its comments explain the choices this inherits.

    /// The bones whose soles are watched, with each one's rest distance to the ground. Four, not
    /// one: an ankle barely moves while a pointed toe goes straight through the floor.
    private var soleOffsets: [(node: SCNNode, offset: Float)] = []
    private var plantOffsetY: Float = 0
    private let soleNodes: [SCNNode]
    private let hipsNode: SCNNode?
    private let torsoLength: Float
    private let groundY: () -> Float?

    /// Called after every pose, with the frame's timestamp. The VRM spring bones are driven here.
    var onFrame: ((TimeInterval) -> Void)?

    var duration: Float { clip.duration }

    /// - Parameters:
    ///   - root: the node the retarget measures model space against - the character's root, so the
    ///     rotation `normalizeOrientation()` puts on it does not enter the math.
    ///   - groundY: the world height of the floor the character stands on, read fresh every frame
    ///     because in AR the user can tap to move the character to another plane at any time.
    ///     Nil disables foot planting, which is what an offscreen thumbnail render wants.
    ///   - bone: VRM humanoid bone name (1.0 spelling) -> the model's node, nil when it has none.
    init?(clip: VRMAnimationClip, root: SCNNode, groundY: @escaping () -> Float? = { nil },
          bone: (String) -> SCNNode?) {
        self.clip = clip
        self.groundY = groundY
        self.hipsNode = bone("hips")
        self.soleNodes = ["leftFoot", "rightFoot", "leftToes", "rightToes"].compactMap(bone)

        // Which source node each humanoid bone is, and which of them the model actually has. The
        // eyes are left out: a VRM aims its gaze through look-at, not through bone animation.
        var targetForNode: [Int: SCNNode] = [:]
        var boneNameForNode: [Int: String] = [:]
        for (name, index) in clip.boneNode {
            boneNameForNode[index] = name
            guard name != "leftEye", name != "rightEye" else { continue }
            if let node = bone(name) { targetForNode[index] = node }
        }

        /// Rest rotation of a model node relative to `root`. Composed from the node's own
        /// orientations rather than read off a world transform, so a scaled ancestor cannot skew it.
        func restRotation(_ node: SCNNode) -> simd_quatf {
            var result = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            var current: SCNNode? = node
            while let step = current, step !== root {
                result = step.simdOrientation * result
                current = step.parent
            }
            return result
        }

        func restMatrix(_ node: SCNNode) -> simd_float4x4 {
            var result = matrix_identity_float4x4
            var current: SCNNode? = node
            while let step = current, step !== root {
                result = step.simdTransform * result
                current = step.parent
            }
            return result
        }

        // Which way the model is built facing, as the rotation from the frame a `.vrma` is
        // authored in (VRM 1.0: +X the character's left, +Y up, +Z forward) into the model's own.
        //
        // This started life as a `facingFlip` flag for VRM 0.x, which faces -Z and so needs half a
        // turn about Y. Measuring it instead covers that case identically - a 0.x rig measures to
        // exactly that half turn - and covers a Mixamo `.scn` too, whose authored frame is whatever
        // the FBX -> USDZ -> SCN conversion left behind and is not worth asserting. It is the same
        // construction `CharacterSceneController.normalizeOrientation()` uses on the root node,
        // read here from the bind pose rather than applied.
        let flip = Self.modelFrame(hips: bone("hips"), head: bone("head"),
                                   leftShoulder: bone("leftShoulder"),
                                   rightShoulder: bone("rightShoulder"),
                                   rest: restMatrix)
        let flipMatrix = simd_float4x4(flip)

        // Scales the planting tolerance and its safety rail, so neither is a magic number in metres.
        if let hips = bone("hips"), let head = bone("head") {
            let a = restMatrix(hips).columns.3, b = restMatrix(head).columns.3
            torsoLength = max(1e-3, simd_length(simd_float3(b.x - a.x, b.y - a.y, b.z - a.z)))
        } else {
            torsoLength = 1
        }

        /// The world rotation a source bone adds to its parent's, in flipped model space.
        func delta(at index: Int) -> Delta? {
            guard let track = clip.rotations[index] else { return nil }
            let parentWorld = clip.nodes[index].parent.map { clip.nodes[$0].worldRotation }
                ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            return Delta(track: track,
                         pre: flip * parentWorld,
                         post: clip.nodes[index].worldRotation.inverse * flip.inverse)
        }

        /// Source bones between `index` and the nearest ancestor the model also has, root first.
        func skippedAncestorDeltas(above index: Int) -> [Delta] {
            var result: [Delta] = []
            var ancestor = clip.nodes[index].parent
            while let current = ancestor {
                if boneNameForNode[current] != nil {
                    guard targetForNode[current] == nil else { break }
                    if let delta = delta(at: current) { result.append(delta) }
                }
                ancestor = clip.nodes[current].parent
            }
            return result.reversed()
        }

        // The hips motion is the only translation retargeted, and it scales by how much taller one
        // rig's hips rest than the other's. Without that a tall model's dance stays glued low.
        var hipsScale: Float = 1
        if let hipsIndex = clip.boneNode["hips"], let hipsNode = targetForNode[hipsIndex] {
            let sourceHeight = clip.nodes[hipsIndex].worldMatrix.columns.3.y
            let targetHeight = restMatrix(hipsNode).columns.3.y
            if sourceHeight > .ulpOfOne, targetHeight > .ulpOfOne {
                hipsScale = targetHeight / sourceHeight
            }
        }
        let modelTransform = flipMatrix
            * simd_float4x4(diagonal: simd_float4(hipsScale, hipsScale, hipsScale, 1))

        var bindings: [Binding] = []
        for (index, node) in targetForNode {
            var deltas = skippedAncestorDeltas(above: index)
            if let own = delta(at: index) { deltas.append(own) }

            var translation: Hips?
            if boneNameForNode[index] == "hips", let track = clip.hipsTranslation,
               !track.values.isEmpty {
                let sourceParent = clip.nodes[index].parent.map { clip.nodes[$0].worldMatrix }
                    ?? matrix_identity_float4x4
                let targetParent = node.parent.map { restMatrix($0) } ?? matrix_identity_float4x4
                let transform = targetParent.inverse * modelTransform * sourceParent
                // Measured after mapping, not on the raw track: a take converted out of Blender
                // carries its height on a different axis than a natively authored one, and which
                // component is "up" only settles once the transform has been applied.
                let mapped = track.values.map { value -> simd_float3 in
                    let v = transform * simd_float4(value, 1)
                    return simd_float3(v.x, v.y, v.z)
                }
                let reference = simd_float3(mapped[0].x,
                                            mapped.map(\.y).min() ?? mapped[0].y,
                                            mapped[0].z)
                translation = Hips(track: track, transform: transform,
                                   reference: reference, rest: node.simdPosition)
            }
            guard !deltas.isEmpty || translation != nil else { continue }

            bindings.append(Binding(node: node,
                                    deltas: deltas,
                                    pre: (node.parent.map { restRotation($0) }
                                          ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)).inverse,
                                    post: restRotation(node),
                                    translation: translation))
        }

        guard !bindings.isEmpty else {
            NSLog("[VRMA] none of the take's %d bones are on this model", clip.boneNode.count)
            return nil
        }
        self.bindings = bindings

        let missing = clip.boneNode.filter { targetForNode[$0.value] == nil && $0.key != "leftEye"
            && $0.key != "rightEye" }.keys.sorted()
        NSLog("[VRMA] bound %d bones, %.1fs%@", bindings.count, clip.duration,
              missing.isEmpty ? "" : ", model has no \(missing.joined(separator: ", "))")

        // The caller resets the skeleton before building a player, so the pose being measured here
        // is the bind pose - which is the only one these offsets mean anything in.
        captureSoles()
    }

    /// The rotation from a `.vrma`'s authored frame into the model's own, read off the bind pose.
    /// Identity when the bones it needs are missing, which leaves the take unrotated.
    private static func modelFrame(hips: SCNNode?, head: SCNNode?,
                                   leftShoulder: SCNNode?, rightShoulder: SCNNode?,
                                   rest: (SCNNode) -> simd_float4x4) -> simd_quatf {
        let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard let hips, let head, let leftShoulder, let rightShoulder else { return identity }
        func position(_ node: SCNNode) -> simd_float3 {
            let c = rest(node).columns.3
            return simd_float3(c.x, c.y, c.z)
        }
        let up = simd_normalize(position(head) - position(hips))
        let across = simd_normalize(position(leftShoulder) - position(rightShoulder))
        guard up.x.isFinite, across.x.isFinite else { return identity }
        let forward = simd_normalize(simd_cross(across, up))
        let left = simd_normalize(simd_cross(up, forward))
        guard forward.x.isFinite, left.x.isFinite else { return identity }
        return simd_quatf(simd_float3x3(left, up, forward))
    }

    func start() {
        stop()
        startTime = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // Above the take's own 30fps on purpose. Sampling is against a continuous clock rather
        // than stepping one stored frame per tick, so the extra ticks cost one slerp per bone and
        // buy real smoothing. It matters: a fast take's forearms turn a median 13 degrees *per
        // authored frame*, and held at 30fps that reads as strobing rather than as speed.
        link.preferredFramesPerSecond = 60
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// `CADisplayLink(target:)` retains its target, so a player left running keeps posing a
    /// skeleton nobody is looking at. Every owner has to call this when its view goes away.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if startTime == 0 { startTime = link.timestamp }

        // 核心优化：引入优雅减速因子 (0.88x)
        // 1.0x 原生速度在小屏幕橱窗里往往显得过于锐利急促，0.88x 能增加动作的重量感与优雅感。
        let speedFactor: Float = 0.88
        let elapsed = Float(link.timestamp - startTime) * speedFactor

        // 优化方案：引入循环呼吸停顿机制
        // 每一个循环周期 = 舞蹈时长 + 1.2秒的静止休息时长
        let restDuration: Float = 1.2
        let totalCycle = clip.duration + restDuration

        if clip.duration > 0 {
            let currentTimeInCycle = elapsed.truncatingRemainder(dividingBy: totalCycle)

            if currentTimeInCycle <= clip.duration {
                // 1. 正常舞蹈时间轴
                apply(at: currentTimeInCycle)
            } else {
                // 2. 呼吸休息时间轴：保持在最后一帧，给予用户视觉喘息
                apply(at: clip.duration)
            }
        } else {
            apply(at: 0)
        }

        onFrame?(link.timestamp)
    }

    /// Pose the model for `time` seconds into the take.
    func apply(at time: Float) {
        // Writing a node transform inside an open transaction would interpolate it over the
        // transaction's duration, which is a second pass of smoothing over already smooth keys.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for binding in bindings {
            binding.node.simdOrientation = binding.rotation(at: time)
            if let hips = binding.translation {
                binding.node.simdPosition = hips.position(at: time)
            }
        }
        // Carried into the hips before the soles are measured, not written onto the node after:
        // the next frame re-sets the hips from the take, which would throw a correction away.
        if plantOffsetY != 0, let hips = hipsNode { hips.simdWorldPosition.y -= plantOffsetY }
        plantFeet()
        SCNTransaction.commit()
    }

    /// Pull the lowest sole back onto the floor, and keep the correction for the next frame.
    ///
    /// Lifted from `PoseRetargeter.plantFeet()`, including the asymmetry: a sole floating a
    /// centimetre above the ground goes unnoticed, a boot sunk into it is the first thing anyone
    /// sees, so a foot below the floor is corrected at full rate and one above it within a
    /// tolerance band is left alone. A take with a real jump has that jump flattened; none in the
    /// library jumps, and a character floating at knee height reads far worse than a lost hop.
    private func plantFeet() {
        // Read live: in AR the ground moves whenever the user taps to place the character
        // somewhere else, and the sole offsets stay valid across that - they are bone-to-sole
        // distances, not absolute heights.
        guard let hips = hipsNode, let ground = groundY() else { return }
        if soleOffsets.isEmpty { return }

        let lowestSole = soleOffsets.map { $0.node.simdWorldPosition.y - $0.offset }.min() ?? ground
        let sole = lowestSole - ground
        let tolerance = torsoLength * 0.02
        let error: Float = sole > tolerance ? sole - tolerance : (sole < 0 ? sole : 0)
        guard error != 0 else { return }

        hips.simdWorldPosition.y -= error
        plantOffsetY += error
        let limit = torsoLength * 0.5
        plantOffsetY = min(max(plantOffsetY, -limit), limit)
    }

    /// Re-measure the soles against the floor the character is standing on now, and drop the
    /// correction built up against the old one.
    ///
    /// Called when the character is re-mounted or moved - screen <-> AR, and every tap-to-place.
    /// Unlike `PoseRetargeter`, nothing else has to be re-captured: the hips are written as a
    /// position local to their parent, so wherever the character's root is anchored, the take
    /// follows it. Only the ground is absolute.
    func rebase() {
        plantOffsetY = 0
        captureSoles()
    }

    /// Each watched bone's height above the floor in the pose it is in now, which the caller
    /// guarantees is the bind pose.
    private func captureSoles() {
        guard let ground = groundY() else {
            soleOffsets = []
            return
        }
        soleOffsets = soleNodes.map { ($0, $0.simdWorldPosition.y - ground) }
    }
}
