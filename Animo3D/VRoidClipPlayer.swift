//
//  VRoidClipPlayer.swift
//  Animo3D
//
//  VRoid(VRM)角色的完整骨骼动画回放:加载离线用 three-vrm 重定向导出的
//  骨骼四元数 JSON(vr_<舞蹈>.json),逐帧套到角色的 J_Bip 骨骼上。
//  比 8 骨简化(PoseRetargeter)完整得多——躯干/头/四肢/末端全动。
//

import Foundation
import SceneKit
import QuartzCore

/// 解析好的一支 VRoid 骨骼动画。
/// 单独抽出来是为了能在**后台线程**解析:vr_*.json 最大 2.5MB,
/// JSONSerialization + 逐帧建字典在主线程要卡 0.5~2s(进舞台页那一下)。
struct VRoidClip {
    let fps: Double
    let frames: [[String: simd_quatf]]

    var isEmpty: Bool { frames.isEmpty }

    /// clipName 不含扩展名,如 "vr_Arms_Hip_Hop_Dance"。**耗时,别在主线程调用。**
    static func load(named clipName: String) -> VRoidClip? {
        guard let url = Bundle.main.url(forResource: clipName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fr = obj["frames"] as? [[String: [Double]]] else {
            NSLog("[VRoidClip] FAIL 找不到/解析失败: %@", clipName)
            return nil
        }
        let fps = (obj["fps"] as? Double) ?? 30
        // 解析阶段就转成四元数并剔掉非四元数项(如 __hipsPos),回放时每帧只做赋值。
        let frames: [[String: simd_quatf]] = fr.map { d in
            var out: [String: simd_quatf] = [:]
            out.reserveCapacity(d.count)
            for (name, v) in d where v.count == 4 {
                out[name] = simd_quatf(ix: Float(v[0]), iy: Float(v[1]), iz: Float(v[2]), r: Float(v[3]))
            }
            return out
        }
        NSLog("[VRoidClip] OK %@ 帧数=%d fps=%.0f", clipName, frames.count, fps)
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
        NSLog("[VRoidClip] 就绪 帧数=%d 场景骨骼数=%d", clip.frames.count, controller.boneNodes.count)
    }

    /// 兼容旧调用:同步解析。**会阻塞调用线程**,新代码请用 `VRoidClip.load` + `init(clip:controller:)`。
    convenience init?(clipName: String, controller: CharacterSceneController) {
        guard let clip = VRoidClip.load(named: clipName) else { return nil }
        self.init(clip: clip, controller: controller)
    }

    var frameCount: Int { clip.frames.count }

    func start() {
        stop()
        startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        // 源动画本身就是 30fps,按 60Hz 跑只是把同一帧重算一遍蒙皮,白烧 GPU/CPU。
        l.preferredFramesPerSecond = DeviceTier.playbackFPS
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// 直接摆到某一帧(缩略图/静态预览用)。
    func pose(frame idx: Int) {
        applyFrame(min(max(0, idx), clip.frames.count - 1))
    }

    @objc private func tick() {
        guard !clip.frames.isEmpty else { return }
        let t = CACurrentMediaTime() - startTime
        let idx = Int(t * clip.fps) % clip.frames.count   // 循环
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
            NSLog("[VRoidClip] tick首帧 命中骨骼=%d/%d", hit, clip.frames[idx].count)
        }
    }
}
