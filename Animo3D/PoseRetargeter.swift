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
    private var characterFrame = simd_float3x3(1)   // 角色躯干坐标系(局部→世界)
    private var captured = false
    private var smoothed: [simd_float3]?             // 时间平滑后的关节点

    init(controller: CharacterSceneController) {
        self.controller = controller
    }

    /// 由“上”方向和“右”方向构造一个正交躯干坐标系（列: 右, 上, 前）。
    /// 右手系：前 = 右 × 上，右 = 上 × 前。source 和 character 用同一构造，保证相对方向一致。
    private static func makeFrame(up upRaw: simd_float3, right rightRaw: simd_float3) -> simd_float3x3 {
        let u = simd_normalize(upRaw)
        let f = simd_normalize(simd_cross(rightRaw, u))
        let r = simd_normalize(simd_cross(u, f))
        return simd_float3x3(r, u, f)
    }

    /// 加载完成后采样一次：每根骨头的静止朝向 + 角色躯干坐标系。
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
        // 角色躯干坐标系：上 = 肩中心-髋中心，右 = 左髋-右髋（世界坐标）
        if let lArm = controller.boneNodes["mixamorig_LeftArm"]?.simdWorldPosition,
           let rArm = controller.boneNodes["mixamorig_RightArm"]?.simdWorldPosition,
           let lUp = controller.boneNodes["mixamorig_LeftUpLeg"]?.simdWorldPosition,
           let rUp = controller.boneNodes["mixamorig_RightUpLeg"]?.simdWorldPosition {
            let shC = (lArm + rArm) / 2
            let hipC = (lUp + rUp) / 2
            characterFrame = Self.makeFrame(up: shC - hipC, right: lUp - rUp)
        }
        captured = !rests.isEmpty
        if captured { print("[Retarget] 采样静止姿态成功，\(rests.count) 根骨头") }
    }

    private var debugLogged = false

    /// 调试用：已知姿势——双臂笔直向前(朝镜头)、双腿垂直站立。
    /// 坐标系约定(实测)：+x=人体左侧, +y=向下, +z=人体后方（正面为 -z）。
    static func debugArmsForwardPose() -> [simd_float3] {
        var p = [simd_float3](repeating: .zero, count: 33)
        // 肩
        p[11] = [ 0.2, -0.4, 0];  p[12] = [-0.2, -0.4, 0]
        // 肘（在肩正前方 = -z）
        p[13] = [ 0.2, -0.4, -0.25]; p[14] = [-0.2, -0.4, -0.25]
        // 腕（更前）
        p[15] = [ 0.2, -0.4, -0.5];  p[16] = [-0.2, -0.4, -0.5]
        // 髋 / 膝 / 踝（垂直向下 = +y）
        p[23] = [ 0.1, 0.0, 0]; p[24] = [-0.1, 0.0, 0]
        p[25] = [ 0.1, 0.5, 0]; p[26] = [-0.1, 0.5, 0]
        p[27] = [ 0.1, 1.0, 0]; p[28] = [-0.1, 1.0, 0]
        return p
    }

    /// 用一帧的 33 个世界坐标驱动骨骼。必须在主线程调用。
    func apply(world: [simd_float3]) {
        captureRestIfNeeded()
        guard captured, world.count >= 33 else { return }

        // 一次性打印关键关节点原始坐标，用解剖关系判定 BlazePose 轴向
        if !debugLogged {
            debugLogged = true
            func p(_ i: Int) -> String {
                let v = world[i]
                return String(format: "(%.2f, %.2f, %.2f)", v.x, v.y, v.z)
            }
            print("[Axis] nose0=\(p(0)) Lsh11=\(p(11)) Rsh12=\(p(12)) Lhip23=\(p(23)) Rhip24=\(p(24)) Lankle27=\(p(27))")
        }

        // 时间平滑：对每个关节点做低通，去抖 / 去顿挫
        let alpha: Float = 0.35
        if smoothed == nil || smoothed!.count != world.count {
            smoothed = world
        } else {
            for i in 0..<world.count {
                smoothed![i] += (world[i] - smoothed![i]) * alpha
            }
        }
        let w = smoothed!

        // 关节点解析：支持虚拟中点（100=肩中心, 101=髋中心）
        func lm(_ i: Int) -> simd_float3 {
            switch i {
            case MixamoBoneMap.shoulderCenter: return (w[11] + w[12]) / 2
            case MixamoBoneMap.hipCenter:      return (w[23] + w[24]) / 2
            default:                            return w[i]
            }
        }

        // 1) 用这一帧的关节点构造“人”的躯干坐标系
        let shC = (w[11] + w[12]) / 2
        let hipC = (w[23] + w[24]) / 2
        let srcFrame = Self.makeFrame(up: shC - hipC, right: w[23] - w[24])
        let srcFrameInv = srcFrame.transpose   // 正交阵，逆=转置：世界→躯干局部

        for r in rests {
            let target = lm(r.def.to) - lm(r.def.from)
            guard simd_length(target) > 1e-4 else { continue }
            // 2) 肢体方向表达为“相对人躯干”的方向
            let dirLocal = simd_normalize(srcFrameInv * simd_normalize(target))
            // 3) 套到角色躯干坐标系，得到角色世界系下的目标方向
            let t = simd_normalize(characterFrame * dirLocal)

            // 4) 把静止朝向旋到目标朝向，再转成相对父骨的本地朝向
            let delta = simd_quatf(from: r.restWorldDir, to: t)
            let desiredWorld = delta * r.restWorldOrient
            let parentWorld = r.node.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: [0, 1, 0])
            let local = parentWorld.inverse * desiredWorld

            r.node.simdOrientation = simd_slerp(r.node.simdOrientation, local, 0.5)
        }
    }
}
