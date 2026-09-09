//
//  PoseRetargeter.swift
//  Animo3D
//
//  Converts BlazePose's 33 3D world-space landmarks (positions) into Mixamo bone rotations that drive the character.
//
//  Approach (per bone):
//   1. Target direction t = normalize(landmark[to] - landmark[from]), mapped into the character frame
//   2. Rest direction restWorldDir = normalize(child bone world position - this bone world position) (sampled once at load)
//   3. delta = the quaternion that rotates restWorldDir onto t
//   4. Desired world orientation = delta * restWorldOrient
//   5. Local orientation = inverse(parent current world orientation) * desired world orientation -> written back to node.simdOrientation
//  Bones are processed parent-first, so a child always uses its parent's freshly updated world orientation.
//

import SceneKit
import simd

final class PoseRetargeter {

    private let controller: BoneRig

    private struct Rest {
        let node: SCNNode
        let restWorldDir: simd_float3
        let restWorldOrient: simd_quatf
        let def: MixamoBoneMap.BoneDef
    }
    private var rests: [Rest] = []
    private var characterFrame = simd_float3x3(1)   // Character torso frame (local -> world)
    private var captured = false
    private var smoothed: [simd_float3]?             // Landmarks after temporal smoothing

    // Hip translation: lets the body sink naturally as the legs bend, giving weight and footing (otherwise the limbs move while the torso stays nailed down, which looks stiff)
    private var hipsNode: SCNNode?
    private var charHipsRestWorld = simd_float3(repeating: 0)
    private var charTorsoLen: Float = 1
    private var srcCaptured = false
    private var srcRestHip = simd_float3(repeating: 0)
    /// The source take's lowest hip height, when the caller knows it. Set before the first frame.
    var sourceHipFloorY: Float?

    /// Per-bone distance from the bone to the sole beneath it, measured in the rest pose against
    /// the real ground plane.
    ///
    /// Four bones, not one: the ankle and the toe of each foot. Watching the ankle alone is what
    /// let the boots keep clipping after the first fix - point the toe or roll the ankle and the
    /// ankle's height barely changes while the sole goes straight through the floor. Subtracting
    /// each bone's own offset turns four bone heights into four estimates of where the sole is.
    private var soleOffsets: [(node: SCNNode, offset: Float)] = []
    private var plantGroundY: Float?

    /// How far the lower foot may leave the ground before it is pulled back, as a fraction of torso
    /// length. Small but not zero: a hard zero fights the hip smoothing and buzzes.
    private let footPlantTolerance: Float = 0.02

    /// How fast the correction builds while the foot is off the ground. Below 1 on purpose - at 1
    /// the double-counting described in plantFeet() comes back through the hip blend.
    private let plantGain: Float = 0.5

    /// How fast the sole is pushed back out once it is *through* the ground. Full rate,
    /// deliberately asymmetric: a foot a centimetre off the floor is not noticeable, a boot sunk
    /// into it is the first thing anyone sees.
    private let plantReleaseGain: Float = 1.0

    /// Accumulated downward correction, carried between frames.
    ///
    /// It has to be part of the hip *target*, not applied to the hip afterwards. The hip is set with
    /// `simd_mix(current, target, 0.5)` every frame, so a correction written straight onto the node
    /// is halved by the next frame's blend and re-diluted forever: measured, that left half the
    /// float still there (0.234 -> 0.171) instead of removing it.
    private var plantOffsetY: Float = 0
    private var srcRestFrame = simd_float3x3(1)      // Source rest torso frame
    private var srcRestFrameInv = simd_float3x3(1)
    private var srcTorsoLen: Float = 1

    // Spine drive: lets the torso twist and lean with the shoulder line (removes the board-like upper body)
    private var spineNode: SCNNode?
    private var spineRestWorldOrient = simd_quatf(angle: 0, axis: [0, 1, 0])
    private let spineGain: Float = 0.7               // Damping, so noise is not amplified and the spine does not overshoot

    init(controller: BoneRig) {
        self.controller = controller
    }

    /// Call after switching presentation scene (screen <-> AR, where the character is re-mounted); the rest pose is re-sampled on the next frame.
    func resetCapture() {
        captured = false
        srcCaptured = false
        smoothed = nil
    }

    /// Builds an orthonormal torso frame from an "up" and a "right" direction (columns: right, up, forward).
    /// Right-handed: forward = right x up, right = up x forward. Source and character use the same construction, which keeps relative directions consistent.
    private static func makeFrame(up upRaw: simd_float3, right rightRaw: simd_float3) -> simd_float3x3 {
        let u = simd_normalize(upRaw)
        let f = simd_normalize(simd_cross(rightRaw, u))
        let r = simd_normalize(simd_cross(u, f))
        return simd_float3x3(r, u, f)
    }

    /// Sampled once after loading: every bone's rest orientation plus the character's torso frame.
    private func captureRestIfNeeded() {
        guard !captured, controller.isLoaded else { return }
        rests.removeAll()
        for def in controller.scheme.bones {
            guard let bone = controller.boneNodes[def.node],
                  let child = controller.boneNodes[def.childNode] else { continue }
            let dir = simd_normalize(child.simdWorldPosition - bone.simdWorldPosition)
            rests.append(Rest(node: bone,
                              restWorldDir: dir,
                              restWorldOrient: bone.simdWorldOrientation,
                              def: def))
        }
        // Character torso frame: up = shoulder center - hip center, right = left hip - right hip (world space)
        let s = controller.scheme
        if let lArm = controller.boneNodes[s.leftArm]?.simdWorldPosition,
           let rArm = controller.boneNodes[s.rightArm]?.simdWorldPosition,
           let lUp = controller.boneNodes[s.leftUpLeg]?.simdWorldPosition,
           let rUp = controller.boneNodes[s.rightUpLeg]?.simdWorldPosition {
            let shC = (lArm + rArm) / 2
            let hipC = (lUp + rUp) / 2
            characterFrame = Self.makeFrame(up: shC - hipC, right: lUp - rUp)
            charTorsoLen = max(1e-3, simd_length(shC - hipC))
        }
        // Hip node plus its rest world position (translation reference)
        // Rest pose, so every sole is on the ground by construction: whatever each bone sits above
        // the plane now is what it will sit above its own sole for the rest of the performance.
        plantGroundY = controller.groundY
        if let ground = controller.groundY {
            soleOffsets = [s.leftFoot, s.rightFoot, s.leftToe, s.rightToe].compactMap { name in
                guard let n = controller.boneNodes[name] else { return nil }
                return (n, n.simdWorldPosition.y - ground)
            }
        } else {
            soleOffsets = []
        }
        hipsNode = controller.boneNodes[s.hips]
        charHipsRestWorld = hipsNode?.simdWorldPosition ?? .init(repeating: 0)
        // Spine bone plus its rest world orientation (torso twist reference)
        spineNode = controller.boneNodes[s.spine]
        spineRestWorldOrient = spineNode?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
        captured = !rests.isEmpty
        if captured { print("[Retarget] rest pose captured, \(rests.count) bones") }
    }

    private var debugLogged = false

    /// Debug helper: a known pose - both arms straight forward (toward the camera), both legs standing vertically.
    /// Axis convention (measured): +x = the body's left, +y = down, +z = behind the body (the front is -z).
    static func debugArmsForwardPose() -> [simd_float3] {
        var p = [simd_float3](repeating: .zero, count: 33)
        // Shoulders
        p[11] = [ 0.2, -0.4, 0];  p[12] = [-0.2, -0.4, 0]
        // Elbows (directly in front of the shoulders = -z)
        p[13] = [ 0.2, -0.4, -0.25]; p[14] = [-0.2, -0.4, -0.25]
        // Wrists (further forward)
        p[15] = [ 0.2, -0.4, -0.5];  p[16] = [-0.2, -0.4, -0.5]
        // Hips / knees / ankles (straight down = +y)
        p[23] = [ 0.1, 0.0, 0]; p[24] = [-0.1, 0.0, 0]
        p[25] = [ 0.1, 0.5, 0]; p[26] = [-0.1, 0.5, 0]
        p[27] = [ 0.1, 1.0, 0]; p[28] = [-0.1, 1.0, 0]
        return p
    }

    /// Drives the skeleton with one frame of 33 world-space landmarks. Must be called on the main thread.
    func apply(world: [simd_float3]) {
        captureRestIfNeeded()
        guard captured, world.count >= 33 else { return }

        // Print the raw coordinates of the key landmarks once, so BlazePose's axes can be worked out from anatomy
        if !debugLogged {
            debugLogged = true
            func p(_ i: Int) -> String {
                let v = world[i]
                return String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
            }
            print("[Axis] nose0=\(p(0)) Lsh11=\(p(11)) Rsh12=\(p(12)) Lhip23=\(p(23)) Rhip24=\(p(24)) Lankle27=\(p(27))")
        }

        // Temporal smoothing: low-pass every landmark to remove jitter and stutter
        let alpha: Float = 0.35
        if smoothed == nil || smoothed!.count != world.count {
            smoothed = world
        } else {
            for i in 0..<world.count {
                smoothed![i] += (world[i] - smoothed![i]) * alpha
            }
        }
        let w = smoothed!

        // Landmark lookup: supports virtual midpoints (100 = shoulder center, 101 = hip center)
        func lm(_ i: Int) -> simd_float3 {
            switch i {
            case MixamoBoneMap.shoulderCenter: return (w[11] + w[12]) / 2
            case MixamoBoneMap.hipCenter:      return (w[23] + w[24]) / 2
            default:                            return w[i]
            }
        }

        // 1) Build the person's torso frame from this frame's landmarks
        let shC = (w[11] + w[12]) / 2
        let hipC = (w[23] + w[24]) / 2
        let srcFrame = Self.makeFrame(up: shC - hipC, right: w[23] - w[24])
        let srcFrameInv = srcFrame.transpose   // Orthonormal matrix, so inverse = transpose: world -> torso local

        // On the first frame, record the source rest reference (hip translation baseline, decomposed in the fixed rest torso frame for stability)
        if !srcCaptured {
            srcCaptured = true
            srcRestHip = hipC
            // Only the vertical baseline is replaced; horizontal drift is still measured from the
            // opening frame, which is where the character is standing.
            if let floorY = sourceHipFloorY { srcRestHip.y = floorY }
            srcRestFrame = srcFrame
            srcRestFrameInv = srcFrame.transpose
            srcTorsoLen = max(1e-3, simd_length(shC - hipC))
        }
        // Hip translation: the source hip displacement from rest -> the character's hip bone (scaled by the torso length ratio).
        // So when the legs bend the hips sink with them and the feet stay on the ground, instead of "legs moving while the body does not".
        if let hips = hipsNode {
            let deltaLocal = srcRestFrameInv * (hipC - srcRestHip)      // Displacement in source torso local space
            let deltaChar = characterFrame * (deltaLocal * (charTorsoLen / srcTorsoLen))
            var target = charHipsRestWorld + deltaChar
            target.y -= plantOffsetY
            hips.simdWorldPosition = simd_mix(hips.simdWorldPosition, target, simd_float3(repeating: 0.5))
        }

        // Spine drive: torso rotation relative to rest -> the character's spine bone (applied before the limbs, which then self-correct against the parent's new orientation).
        if let spine = spineNode {
            let rLocal = srcRestFrameInv * srcFrame                     // Torso rotation relative to rest (in torso local space)
            let rChar = characterFrame * rLocal * characterFrame.transpose  // Into the character's world basis
            var q = simd_quatf(rChar)
            q = simd_slerp(simd_quatf(angle: 0, axis: [0, 1, 0]), q, spineGain)   // Damping
            let desiredWorld = q * spineRestWorldOrient
            let parentWorld = spine.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let local = parentWorld.inverse * desiredWorld
            spine.simdOrientation = simd_slerp(spine.simdOrientation, local, 0.5)
        }

        for r in rests {
            let target = lm(r.def.to) - lm(r.def.from)
            guard simd_length(target) > 1e-4 else { continue }
            // 2) Express the limb direction relative to the person's torso
            let dirLocal = simd_normalize(srcFrameInv * simd_normalize(target))
            // 3) Apply it to the character's torso frame to get the target direction in the character's world space
            let t = simd_normalize(characterFrame * dirLocal)

            // 4) Rotate the rest orientation onto the target, then convert it to a local orientation relative to the parent
            let delta = simd_quatf(from: r.restWorldDir, to: t)
            let desiredWorld = delta * r.restWorldOrient
            let parentWorld = r.node.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let local = parentWorld.inverse * desiredWorld

            r.node.simdOrientation = simd_slerp(r.node.simdOrientation, local, 0.5)
        }

        plantFeet()
    }

    /// Pull the character back down until its lower foot is on the ground again.
    ///
    /// Hip translation and limb driving are supposed to cancel: as the source dancer rises out of a
    /// crouch the hips go up and the legs straighten, and the feet stay planted. They only cancel
    /// if the character's legs are the same length as the source's, which they are not - the hips
    /// are translated by the source displacement scaled by *torso* length, and the residual is pure
    /// float. Measured on Arms Hip Hop Dance with Erika: the lower foot sat up to 0.23 above its
    /// rest height, about 14% of body height, for the whole dance.
    ///
    /// Enforcing the constraint directly is the only version of this that holds for every
    /// (character, dance) pair. Note the cost: a take with a genuine jump has that jump flattened.
    /// None of the current library jumps, and a character floating at knee height for 20 seconds is
    /// a far worse artefact than a lost hop.
    private func plantFeet() {
        // Read live rather than using the value captured with the rest pose: in AR the ground moves
        // whenever the user taps to place the character somewhere else, and no rest re-capture is
        // triggered for that. `soleOffsets` stay valid across the move - they are ankle-to-sole
        // distances, not absolute heights - so a fresh plane is all this needs.
        guard let hips = hipsNode, let ground = controller.groundY ?? plantGroundY,
              !soleOffsets.isEmpty else { return }

        // Height of the lowest sole above the floor. Negative means it is through the floor.
        let lowestSole = soleOffsets.map { $0.node.simdWorldPosition.y - $0.offset }.min() ?? ground
        let sole = lowestSole - ground
        let tolerance = charTorsoLen * footPlantTolerance

        // How far out of bounds the sole is: positive when floating above the tolerance band,
        // negative when it is through the floor, zero inside the band.
        let error: Float = sole > tolerance ? sole - tolerance : (sole < 0 ? sole : 0)
        guard error != 0 else { return }

        // Corrected on this frame *and* carried in the offset, which is what makes the sole land on
        // the floor rather than approach it. Two earlier versions each got half of this:
        //
        //  - Offset only: the hips are re-set to the target every frame and blended 50/50, so the
        //    correction was diluted and the sole only ever converged part-way.
        //  - Node only, plus an offset measured against the *bone's own rest height*: that quantity
        //    carries a systematic bias, the offset accumulated it, and the character sank into the
        //    floor until the sign flipped and it bounced. The measurement was the bug, not the
        //    double application - `sole` here is an absolute distance to the actual ground plane,
        //    so applying it twice is a fixed-point iteration, not a compounding error.
        //
        // A positive offset lowers the character, a negative one lifts it, and both directions are
        // needed. An earlier version clamped the offset at zero because the character "must not be
        // lifted above the source motion" - that is precisely why the boots kept clipping, because
        // when the retargeted pose itself puts a sole under the floor only a lift can fix it.
        // Between fidelity to the source and not driving a boot through the ground, the ground
        // wins: nobody notices a centimetre of licence, everybody notices clipping.
        hips.simdWorldPosition.y -= error
        plantOffsetY += error

        // Safety rail, both ways: no clip should be able to bury or launch the character.
        let limit = charTorsoLen * 0.5
        plantOffsetY = min(max(plantOffsetY, -limit), limit)
    }
}
