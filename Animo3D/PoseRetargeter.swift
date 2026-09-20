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
import QuartzCore

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

    /// Adaptive filter for each landmark.
    private struct OneEuroFilter {
        var minCutoff: Float = 1.0     // Decrease to reduce jitter in slow motion
        var beta: Float = 0.01          // Increase to reduce lag in fast motion
        var dCutoff: Float = 1.0

        var lastValue: simd_float3?
        var lastDeriv: simd_float3 = .zero
        var lastTime: Double?

        mutating func filter(value: simd_float3, time: Double) -> simd_float3 {
            guard let prevValue = lastValue, let prevTime = lastTime else {
                lastValue = value
                lastTime = time
                return value
            }
            let dt = Float(time - prevTime)
            guard dt > 0.0001 else { return prevValue }

            let deriv = (value - prevValue) / dt
            let aD = alpha(cutoff: dCutoff, dt: dt)
            lastDeriv = simd_mix(lastDeriv, deriv, simd_float3(repeating: aD))

            let cutoff = minCutoff + beta * simd_length(lastDeriv)
            let a = alpha(cutoff: cutoff, dt: dt)
            let result = simd_mix(prevValue, value, simd_float3(repeating: a))

            lastValue = result
            lastTime = time
            return result
        }

        private func alpha(cutoff: Float, dt: Float) -> Float {
            let tau = 1.0 / (2.0 * .pi * cutoff)
            return 1.0 / (1.0 + tau / dt)
        }
    }
    private var filters: [OneEuroFilter] = []
    private var smoothed: [simd_float3]?             // Landmarks after temporal smoothing

    private var leftLegIK: SCNIKConstraint?
    private var rightLegIK: SCNIKConstraint?

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

    // Spine drive: distribute torso rotation across the spine chain for natural flexibility
    private struct SpineRest {
        let node: SCNNode
        let restWorldOrient: simd_quatf
    }
    private var spineChain: [SpineRest] = []
    private let spineGain: Float = 0.7               // Damping, so noise is not amplified and the spine does not overshoot

    // Hand pose simulation
    private struct HandBones {
        let side: String
        let fingers: [[SCNNode]] // [Thumb chain, Index chain, ...]
    }
    private var leftHand: HandBones?
    private var rightHand: HandBones?

    init(controller: BoneRig) {
        self.controller = controller
    }

    /// Call after switching presentation scene (screen <-> AR, where the character is re-mounted); the rest pose is re-sampled on the next frame.
    func resetCapture() {
        captured = false
        srcCaptured = false
        smoothed = nil
        filters.removeAll()

        // Clean up constraints from bones
        let s = controller.scheme
        controller.boneNodes[s.leftFoot]?.constraints = controller.boneNodes[s.leftFoot]?.constraints?.filter { !($0 is SCNIKConstraint) }
        controller.boneNodes[s.rightFoot]?.constraints = controller.boneNodes[s.rightFoot]?.constraints?.filter { !($0 is SCNIKConstraint) }
        leftLegIK = nil
        rightLegIK = nil
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

        // Capture spine chain (Spine, Chest, UpperChest) to distribute rotation naturally
        spineChain.removeAll()
        let spineNames = [s.spine, s.chest, s.upperChest].compactMap { $0 }
        for name in spineNames {
            if let node = controller.boneNodes[name] {
                spineChain.append(SpineRest(node: node, restWorldOrient: node.simdWorldOrientation))
            }
        }

        leftHand = captureHand(left: true)
        rightHand = captureHand(left: false)

        captured = !rests.isEmpty
        if captured {
            setupIK()
            print("[Retarget] rest pose captured, \(rests.count) bones")
        }
    }

    private func setupIK() {
        let s = controller.scheme
        guard let lUp = controller.boneNodes[s.leftUpLeg],
              let lFoot = controller.boneNodes[s.leftFoot],
              let rUp = controller.boneNodes[s.rightUpLeg],
              let rFoot = controller.boneNodes[s.rightFoot] else { return }

        // Remove old IK constraints if any (ensure we don't stack them)
        lFoot.constraints = lFoot.constraints?.filter { !($0 is SCNIKConstraint) }
        rFoot.constraints = rFoot.constraints?.filter { !($0 is SCNIKConstraint) }

        let lik = SCNIKConstraint.inverseKinematicsConstraint(chainRootNode: lUp)
        lik.influenceFactor = 0 // Start disabled, plantFeet() will enable it
        lFoot.constraints = (lFoot.constraints ?? []) + [lik]
        leftLegIK = lik

        let rik = SCNIKConstraint.inverseKinematicsConstraint(chainRootNode: rUp)
        rik.influenceFactor = 0
        rFoot.constraints = (rFoot.constraints ?? []) + [rik]
        rightLegIK = rik
    }

    private func captureHand(left: Bool) -> HandBones? {
        let side = left ? "left" : "right"
        var chains: [[SCNNode]] = []
        for finger in ["Thumb", "Index", "Middle", "Ring", "Little"] {
            var chain: [SCNNode] = []
            for j in 1...3 {
                let vrmName = "\(side)\(finger)\(j == 1 ? (finger == "Thumb" ? "Metacarpal" : "Proximal") : (j == 2 ? (finger == "Thumb" ? "Proximal" : "Intermediate") : "Distal"))"
                if let node = controller.boneNodes[MixamoBoneMap.humanoid[vrmName] ?? ""] {
                    chain.append(node)
                }
            }
            if !chain.isEmpty { chains.append(chain) }
        }
        return chains.isEmpty ? nil : HandBones(side: side, fingers: chains)
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

        // Temporal smoothing: One Euro Filter to remove jitter while maintaining low lag for fast motion
        let currentTime = CACurrentMediaTime()
        if filters.count != world.count {
            filters = Array(repeating: OneEuroFilter(), count: world.count)
        }
        var w = [simd_float3](repeating: .zero, count: world.count)
        for i in 0..<world.count {
            w[i] = filters[i].filter(value: world[i], time: currentTime)
        }
        smoothed = w

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

        // Spine drive: distribute torso rotation across the spine chain (removes the board-like upper body)
        if !spineChain.isEmpty {
            let rLocal = srcRestFrameInv * srcFrame                     // Torso rotation relative to rest (in torso local space)
            let rChar = characterFrame * rLocal * characterFrame.transpose  // Into the character's world basis
            let fullQ = simd_quatf(rChar)

            // Distribute the rotation equally across all available spine bones
            let angle = fullQ.angle
            let axis = fullQ.axis
            let portionQ = simd_quatf(angle: angle / Float(spineChain.count), axis: axis)

            for sr in spineChain {
                var q = simd_slerp(simd_quatf(angle: 0, axis: [0, 1, 0]), portionQ, spineGain) // Damping
                let desiredWorld = q * sr.restWorldOrient
                let parentWorld = sr.node.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
                let local = parentWorld.inverse * desiredWorld
                sr.node.simdOrientation = simd_slerp(sr.node.simdOrientation, local, 0.5)
            }
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

        driveFingers(left: true)
        driveFingers(left: false)

        plantFeet()
    }

    private func driveFingers(left: Bool) {
        guard let hand = left ? leftHand : rightHand else { return }

        // Landmark speed heuristic: faster hand movement -> tighter curl
        let wristIdx = left ? 15 : 16
        let speed = filters.indices.contains(wristIdx) ? simd_length(filters[wristIdx].lastDeriv) : 0
        let curlFactor = min(1.0, max(0.2, speed * 0.5)) // 0.2 (relaxed) to 1.0 (clenched)

        let t = CACurrentMediaTime()
        for (i, chain) in hand.fingers.enumerated() {
            for (j, node) in chain.enumerated() {
                // Heuristic: Thumb curls less, Index/Middle/Ring/Pinky curl progressively more
                let fingerBaseCurl = Float(i) * 0.1
                let jointCurl = Float(j + 1) * 0.4
                let angle = (fingerBaseCurl + jointCurl) * curlFactor

                // Add a tiny bit of "life" noise
                let noise = sin(Float(t) * 2.0 + Float(i) * 0.5) * 0.05

                // Curl around the local X axis (typical for Mixamo/Humanoid finger bones)
                let targetLocal = simd_quatf(angle: angle + noise, axis: simd_float3(1, 0, 0))
                node.simdOrientation = simd_slerp(node.simdOrientation, targetLocal, 0.1)
            }
        }
    }

    /// Pull the character back down until its lower foot is on the ground again.
    ///
    /// Uses a two-stage approach:
    /// 1. Global hip shift to handle large vertical movements and "body weight".
    /// 2. SCNIKConstraint (IK) for each leg to ensure precise foot planting and prevent clipping.
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

        // 1) Coarse adjustment: shift the entire body if it is floating or buried.
        let error: Float = sole > tolerance ? sole - tolerance : (sole < 0 ? sole : 0)
        if error != 0 {
            hips.simdWorldPosition.y -= error
            plantOffsetY += error
            let limit = charTorsoLen * 0.5
            plantOffsetY = min(max(plantOffsetY, -limit), limit)
        }

        // 2) Fine adjustment: use IK to keep both feet firmly on the ground without clipping.
        updateFootIK(left: true, ground: ground)
        updateFootIK(left: false, ground: ground)
    }

    private func updateFootIK(left: Bool, ground: Float) {
        let s = controller.scheme
        let footName = left ? s.leftFoot : s.rightFoot
        let toeName = left ? s.leftToe : s.rightToe
        guard let foot = controller.boneNodes[footName],
              let toe = controller.boneNodes[toeName],
              let ik = left ? leftLegIK : rightLegIK else { return }

        let footOffset = soleOffsets.first { $0.node === foot }?.offset ?? 0
        let toeOffset = soleOffsets.first { $0.node === toe }?.offset ?? 0

        // Calculate current sole heights (lowest point of foot/toe)
        let footSoleY = foot.simdWorldPosition.y - footOffset
        let toeSoleY = toe.simdWorldPosition.y - toeOffset
        let lowestSoleY = min(footSoleY, toeSoleY)

        // If the sole is through the ground, or very close to it, enable IK to lock it.
        // We use a small buffer to avoid flickering.
        if lowestSoleY < ground + 0.005 {
            var targetPos = foot.simdWorldPosition
            targetPos.y += (ground - lowestSoleY)
            ik.targetPosition = SCNVector3(targetPos)
            ik.influenceFactor = 1.0
        } else {
            ik.influenceFactor = 0.0
        }
    }
}
