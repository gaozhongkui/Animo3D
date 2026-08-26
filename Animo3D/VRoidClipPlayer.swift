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

final class VRoidClipPlayer {
    private weak var controller: CharacterSceneController?
    private var frames: [[String: [Float]]] = []
    private var fps: Double = 30
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0

    /// clipName 不含扩展名,如 "vr_Arms_Hip_Hop_Dance"。
    init?(clipName: String, controller: CharacterSceneController) {
        guard let url = Bundle.main.url(forResource: clipName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fr = obj["frames"] as? [[String: [Double]]] else {
            NSLog("[VRoidClip] FAIL 找不到/解析失败: %@", clipName)
            return nil
        }
        self.controller = controller
        self.fps = (obj["fps"] as? Double) ?? 30
        self.frames = fr.map { d in d.mapValues { $0.map { Float($0) } } }
        NSLog("[VRoidClip] OK %@ 帧数=%d 场景骨骼数=%d", clipName, frames.count, controller.boneNodes.count)
    }
    private var ticked = false

    var frameCount: Int { frames.count }

    func start() {
        stop()
        startTime = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// 直接摆到某一帧(缩略图/静态预览用)。
    func pose(frame idx: Int) {
        applyFrame(min(max(0, idx), frames.count - 1))
    }

    @objc private func tick() {
        guard !frames.isEmpty else { return }
        let t = CACurrentMediaTime() - startTime
        let idx = Int(t * fps) % frames.count   // 循环
        applyFrame(idx)
    }

    private func applyFrame(_ idx: Int) {
        guard let c = controller, frames.indices.contains(idx) else { return }
        var hit = 0
        for (name, v) in frames[idx] where name != "__hipsPos" {
            guard v.count == 4, let node = c.boneNodes[name] else { continue }
            node.simdOrientation = simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3])
            hit += 1
        }
        if !ticked { ticked = true; NSLog("[VRoidClip] tick首帧 命中骨骼=%d/%d 样例=%@", hit, frames[idx].count, frames[idx].keys.sorted().prefix(3).joined(separator: ",")) }
    }
}
