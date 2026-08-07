//
//  PoseRetargeter.swift
//  Animo3D
//
//  把 BlazePose 的 33 个 3D 世界坐标（位置）转换成 Mixamo 骨骼旋转，驱动角色。
//
//  思路（每根骨头）：
//   1. 目标朝向 t = 归一化(landmark[to] - landmark[from])，转到角色坐标系
//   2. 静止朝向 restWorldDir = 归一化(子骨世界位置 - 本骨世界位置)（加载时采样一次）
//   3. delta = 把 restWorldDir 旋到 t 的四元数
//   4. 期望世界朝向 = delta * restWorldOrient
//   5. 本地朝向 = inverse(父骨当前世界朝向) * 期望世界朝向  → 写回 node.simdOrientation
//  按“父在前子在后”的顺序处理，父骨更新后子骨才用其最新世界朝向。
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
    private var captured = false

    init(controller: CharacterSceneController) {
        self.controller = controller
    }

    /// 加载完成后采样一次静止姿态。
    private func captureRestIfNeeded() {
        guard !captured, controller.isLoaded else { return }
        rests.removeAll()
        for def in MixamoBoneMap.bones {
            guard let bone = controller.boneNodes[def.node],
                  let child = controller.boneNodes[def.childNode] else { continue }
            let dir = simd_normalize(child.simdWorldPosition - bone.simdWorldPosition)
            rests.append(Rest(node: bone,
                              restWorldDir: dir,
                              restWorldOrient: bone.simdWorldOrientation,
                              def: def))
        }
        captured = !rests.isEmpty
        if captured { print("[Retarget] 采样静止姿态成功，\(rests.count) 根骨头") }
    }

    /// BlazePose 世界坐标 → 角色坐标系（右手、Y 向上）。
    /// MediaPipe world: x 右, y 下, z 朝相机。这里翻转 y、z 作为初值（后续可微调）。
    private func toCharacter(_ v: simd_float3) -> simd_float3 {
        simd_float3(v.x, -v.y, -v.z)
    }

    /// 用一帧的 33 个世界坐标驱动骨骼。必须在主线程调用。
    func apply(world: [simd_float3]) {
        captureRestIfNeeded()
        guard captured, world.count >= 33 else { return }

        for r in rests {
            let from = toCharacter(world[r.def.from])
            let to = toCharacter(world[r.def.to])
            let target = to - from
            guard simd_length(target) > 1e-4 else { continue }
            let t = simd_normalize(target)

            // 把静止朝向旋到目标朝向
            let delta = simd_quatf(from: r.restWorldDir, to: t)
            let desiredWorld = delta * r.restWorldOrient

            // 转成相对父骨的本地朝向
            let parentWorld = r.node.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let local = parentWorld.inverse * desiredWorld

            // 平滑一点，减小抖动
            r.node.simdOrientation = simd_slerp(r.node.simdOrientation, local, 0.5)
        }
    }
}
