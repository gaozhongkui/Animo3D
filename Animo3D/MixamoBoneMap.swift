//
//  MixamoBoneMap.swift
//  Animo3D
//
//  BlazePose 33 点 → Mixamo 标准骨骼 的映射。
//  转成 USDZ 后 Mixamo 骨骼名以 "mixamorig_" 前缀（冒号被转为下划线），命名固定通用。
//
//  BlazePose 索引参考:
//  11 左肩 12 右肩 13 左肘 14 右肘 15 左腕 16 右腕
//  23 左髋 24 右髋 25 左膝 26 右膝 27 左踝 28 右踝
//

import Foundation

enum MixamoBoneMap {

    /// 一根骨头：由骨骼节点 + 其子骨骼节点（用于求静止朝向），
    /// 以及一对 BlazePose 索引（用于求目标朝向）。
    struct BoneDef {
        let node: String        // 骨骼节点名
        let childNode: String   // 子骨骼节点名（静止朝向 = 指向子节点的方向）
        let from: Int           // 目标朝向起点 landmark
        let to: Int             // 目标朝向终点 landmark
    }

    /// 先驱动四肢（最明显、子节点清晰）。躯干/手指后续再加。
    /// 顺序为“父在前、子在后”，保证重定向时父骨的世界朝向已更新。
    static let bones: [BoneDef] = [
        // 左臂
        BoneDef(node: "mixamorig_LeftArm",      childNode: "mixamorig_LeftForeArm", from: 11, to: 13),
        BoneDef(node: "mixamorig_LeftForeArm",  childNode: "mixamorig_LeftHand",    from: 13, to: 15),
        // 右臂
        BoneDef(node: "mixamorig_RightArm",     childNode: "mixamorig_RightForeArm", from: 12, to: 14),
        BoneDef(node: "mixamorig_RightForeArm", childNode: "mixamorig_RightHand",    from: 14, to: 16),
        // 左腿
        BoneDef(node: "mixamorig_LeftUpLeg",    childNode: "mixamorig_LeftLeg",     from: 23, to: 25),
        BoneDef(node: "mixamorig_LeftLeg",      childNode: "mixamorig_LeftFoot",    from: 25, to: 27),
        // 右腿
        BoneDef(node: "mixamorig_RightUpLeg",   childNode: "mixamorig_RightLeg",    from: 24, to: 26),
        BoneDef(node: "mixamorig_RightLeg",     childNode: "mixamorig_RightFoot",   from: 26, to: 28),
        // 注：头/脖子驱动会把头甩到后面（鼻子相对肩中心的朝向不稳），先不驱动，头保持朝前更自然。
    ]

    /// 虚拟关节点索引：100=肩中心, 101=髋中心
    static let shoulderCenter = 100
    static let hipCenter = 101

    static let rootNode = "mixamorig_Hips"
}
