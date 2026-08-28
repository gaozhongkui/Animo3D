//
//  VRoidClipPlayer.swift
//  Animo3D
//
//  Full skeletal animation playback for VRoid (VRM) characters: loads the bone quaternion JSON
//  (vr_<dance>.json) exported offline via three-vrm retargeting, and applies it frame by frame to the character's J_Bip bones.
//  Far more complete than the simplified 8-bone path (PoseRetargeter) - torso, head, limbs and extremities all move.
//

import Foundation
import SceneKit
import QuartzCore

/// One parsed VRoid skeletal animation.
/// It is a separate type so parsing can happen on a **background thread**: vr_*.json reaches 2.5MB, and
/// JSONSerialization plus building the per-frame dictionaries blocks the main thread for 0.5-2s (the hitch when entering the stage page).
struct VRoidClip {
    let fps: Double
    let frames: [[String: simd_quatf]]

    var isEmpty: Bool { frames.isEmpty }

    /// clipName excludes the extension, e.g. "vr_Arms_Hip_Hop_Dance". **Expensive, do not call on the main thread.**
    static func load(named clipName: String) -> VRoidClip? {
        guard let url = Bundle.main.url(forResource: clipName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fr = obj["frames"] as? [[String: [Double]]] else {
            NSLog("[VRoidClip] FAIL not found or parse error: %@", clipName)
            return nil
        }
        let fps = (obj["fps"] as? Double) ?? 30
        // Quaternions are built and non-quaternion entries (such as __hipsPos) dropped during parsing, so playback only assigns values per frame.
        let frames: [[String: simd_quatf]] = fr.map { d in
            var out: [String: simd_quatf] = [:]
            out.reserveCapacity(d.count)
            for (name, v) in d where v.count == 4 {
                out[name] = simd_quatf(ix: Float(v[0]), iy: Float(v[1]), iz: Float(v[2]), r: Float(v[3]))
            }
            return out
        }
        NSLog("[VRoidClip] OK %@ frames=%d fps=%.0f", clipName, frames.count, fps)
        return VRoidClip(fps: fps, frames: frames)
    }
}

final class VRoidClipPlayer {
    private weak var controller: CharacterSceneController?
    private let clip: VRoidClip
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var ticked = false

    init(clip: VRoidClip, controller: CharacterSceneController) {
        self.clip = clip
        self.controller = controller
        NSLog("[VRoidClip] ready frames=%d sceneBones=%d", clip.frames.count, controller.boneNodes.count)
    }

    /// Compatibility with older callers: synchronous parsing. **Blocks the calling thread**; new code should use `VRoidClip.load` + `init(clip:controller:)`.
    convenience init?(clipName: String, controller: CharacterSceneController) {
        guard let clip = VRoidClip.load(named: clipName) else { return nil }
        self.init(clip: clip, controller: controller)
    }

    var frameCount: Int { clip.frames.count }

    func start() {
        stop()
        startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        // The source animation is 30fps anyway, so running at 60Hz just re-skins the same frame and burns GPU/CPU for nothing.
        l.preferredFramesPerSecond = DeviceTier.playbackFPS
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Jump straight to a given frame (used by thumbnails and static previews).
    func pose(frame idx: Int) {
        applyFrame(min(max(0, idx), clip.frames.count - 1))
    }

    @objc private func tick() {
        guard !clip.frames.isEmpty else { return }
        let t = CACurrentMediaTime() - startTime
        let idx = Int(t * clip.fps) % clip.frames.count   // Loop
        applyFrame(idx)
    }

    private func applyFrame(_ idx: Int) {
        guard let c = controller, clip.frames.indices.contains(idx) else { return }
        var hit = 0
        for (name, q) in clip.frames[idx] {
            guard let node = c.boneNodes[name] else { continue }
            node.simdOrientation = q
            hit += 1
        }
        if !ticked {
            ticked = true
            NSLog("[VRoidClip] first tick matchedBones=%d/%d", hit, clip.frames[idx].count)
        }
    }
}
