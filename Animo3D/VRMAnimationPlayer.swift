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
        /// Hips only: takes the source's local translation into the target's parent space.
        let translation: (track: VRMAnimationClip.VectorTrack, transform: simd_float4x4)?

        func rotation(at time: Float) -> simd_quatf {
            deltas.reduce(pre) { $0 * $1.value(at: time) } * post
        }
    }

    private let clip: VRMAnimationClip
    private let bindings: [Binding]
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    /// Called after every pose, with the frame's timestamp. The VRM spring bones are driven here.
    var onFrame: ((TimeInterval) -> Void)?

    var duration: Float { clip.duration }

    /// - Parameters:
    ///   - root: the node the retarget measures model space against - the character's root, so the
    ///     rotation `normalizeOrientation()` puts on it does not enter the math.
    ///   - facingFlip: true for a VRM 0.x model, which faces the opposite way from a `.vrma`.
    ///   - bone: VRM humanoid bone name (1.0 spelling) -> the model's node, nil when it has none.
    init?(clip: VRMAnimationClip, root: SCNNode, facingFlip: Bool, bone: (String) -> SCNNode?) {
        self.clip = clip

        let flip = facingFlip
            ? simd_quatf(angle: .pi, axis: simd_float3(0, 1, 0))
            : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let flipMatrix = simd_float4x4(flip)

        // Which source node each humanoid bone is, and which of them the model actually has. The
        // eyes are left out: a VRM aims its gaze through look-at, not through bone animation.
        var targetForNode: [Int: SCNNode] = [:]
        var boneNameForNode: [Int: String] = [:]
        for (name, index) in clip.boneNode {
            boneNameForNode[index] = name
            guard name != "leftEye", name != "rightEye" else { continue }
            if let node = bone(name) { targetForNode[index] = node }
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

            var translation: (VRMAnimationClip.VectorTrack, simd_float4x4)?
            if boneNameForNode[index] == "hips", let track = clip.hipsTranslation {
                let sourceParent = clip.nodes[index].parent.map { clip.nodes[$0].worldMatrix }
                    ?? matrix_identity_float4x4
                let targetParent = node.parent.map { restMatrix($0) } ?? matrix_identity_float4x4
                translation = (track, targetParent.inverse * modelTransform * sourceParent)
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
    }

    func start() {
        stop()
        startTime = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // The take is authored at 30fps; sampling it twice per key only burns battery.
        link.preferredFramesPerSecond = 30
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
        let elapsed = Float(link.timestamp - startTime)
        apply(at: clip.duration > 0 ? elapsed.truncatingRemainder(dividingBy: clip.duration) : 0)
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
            if let (track, transform) = binding.translation {
                let value = track.value(at: time)
                let position = transform * simd_float4(value, 1)
                binding.node.simdPosition = simd_float3(position.x, position.y, position.z)
            }
        }
        SCNTransaction.commit()
    }
}
