//
//  DeviceTier.swift
//  Animo3D
//
//  设备性能分级:低端机(RAM<4GB,约 iPhone X/XR/SE 及更老)自动降级重特效,
//  关闭 bloom 后处理、降粒子密度、降抗锯齿,避免卡顿。
//

import Foundation
import SceneKit

enum DeviceTier {
    /// 物理内存 < 4GB 视为低端(A11 及更早,或低配)。
    static let isLowEnd: Bool = ProcessInfo.processInfo.physicalMemory < UInt64(4) * 1024 * 1024 * 1024

    /// bloom 辉光强度:低端关闭(0),高端 1.1。
    static var bloomIntensity: CGFloat { isLowEnd ? 0 : 1.1 }

    /// 粒子发射率系数:低端 0.45,高端 1.0。
    static var particleScale: CGFloat { isLowEnd ? 0.45 : 1.0 }

    /// 实时/表演视图抗锯齿:低端关闭,高端 2x(4x 太重,不用)。
    static var antialiasing: SCNAntialiasingMode { isLowEnd ? .none : .multisampling2X }

    /// 缩略图离屏渲染抗锯齿。
    static var thumbAntialiasing: SCNAntialiasingMode { isLowEnd ? .none : .multisampling2X }

    /// 低端不在选舞蹈卡片上跑"实时跳动"(LiveDanceView),用静态姿势图代替。
    static var allowsLiveDanceCards: Bool { !isLowEnd }

    /// 舞台地板实时反射:低端关闭。反射等于把整个场景多渲一遍,和阴影一样是大头。
    static var floorReflectivity: CGFloat { isLowEnd ? 0 : 0.16 }

    /// 天空模式地板倒影强度(天空模式只靠倒影,低端也压低但不全关)。
    static var skyFloorReflectivity: CGFloat { isLowEnd ? 0 : 0.5 }

    /// 方向光实时软阴影:低端关闭,脚下接触阴影贴图已给足着地感。
    static var dynamicShadows: Bool { !isLowEnd }

    /// 软阴影采样数:原来固定 16 太重(forward 模式每帧一遍 shadow pass)。
    static var shadowSampleCount: Int { isLowEnd ? 4 : 8 }

    /// 骨骼回放帧率:动捕源本身就是 30fps,没必要按 60Hz 重算蒙皮。
    static var playbackFPS: Int { 30 }
}
