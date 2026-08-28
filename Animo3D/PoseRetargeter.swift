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

    private let controller: CharacterSceneController

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
    private var srcRestFrame = simd_float3x3(1)      // Source rest torso frame
    private var srcRestFrameInv = simd_float3x3(1)
    private var srcTorsoLen: Float = 1

    // Spine drive: lets the torso twist and lean with the shoulder line (removes the board-like upper body)
    private var spineNode: SCNNode?
    private var spineRestWorldOrient = simd_quatf(angle: 0, axis: [0, 1, 0])
    private let spineGain: Float = 0.7               // Damping, so noise is not amplified and the spine does not overshoot

    init(controller: CharacterSceneController) {
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
            srcRestFrame = srcFrame
            srcRestFrameInv = srcFrame.transpose
            srcTorsoLen = max(1e-3, simd_length(shC - hipC))
        }
        // Hip translation: the source hip displacement from rest -> the character's hip bone (scaled by the torso length ratio).
        // So when the legs bend the hips sink with them and the feet stay on the ground, instead of "legs moving while the body does not".
        if let hips = hipsNode {
            let deltaLocal = srcRestFrameInv * (hipC - srcRestHip)      // Displacement in source torso local space
            let deltaChar = characterFrame * (deltaLocal * (charTorsoLen / srcTorsoLen))
            let target = charHipsRestWorld + deltaChar
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
    }
}
