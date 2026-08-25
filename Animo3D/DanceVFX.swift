//
//  DanceVFX.swift
//  Animo3D
//
//  舞台特效：多种可切换的粒子预设(光罩 / 星尘 / 爱心 / 火花 / 星轨),
//  每种都跟着音乐实时能量(MusicController.currentLevel)脉动。
//  纯代码生成(粒子系统 + 贴图),挂在角色场景根节点,屏幕/AR 共用。
//

import SceneKit
import UIKit
import QuartzCore

/// 一个特效预设的配置。
struct VFXPreset {
    let name: String
    let colors: [UIColor]        // [粒子主色, 环/涟漪色]
    let shape: Shape             // 粒子形状贴图
    let emit: Emit               // 发射方式
    let rise: CGFloat            // 上升速度系数(×身高)
    let arc: CGFloat             // 回落重力系数(0=直上,>0 拱形)
    let size: CGFloat
    let birthBase: CGFloat       // 基础发射率
    let life: CGFloat            // 粒子寿命(秒),越短拖尾/范围越小
    let spin: CGFloat            // 粒子自转
    let stretch: CGFloat         // 沿运动方向拖尾(0=不拖尾)
    let additive: Bool
    let groundRing: Bool
    let ripples: Bool
    let notes: Bool

    enum Shape { case dot, star, heart, spark, note }
    enum Emit { case footRing, bodySphere, chest, spiral }   // 脚底圈 / 全身球 / 胸口 / 螺旋上升

    static let all: [VFXPreset] = [
        // 0 光罩：脚底一圈向上喷出的柔和光粒,聚成半球光罩
        VFXPreset(name: "光罩", colors: [c(0.45,0.8,1), c(0.6,0.5,1)], shape: .dot, emit: .footRing,
                  rise: 0.9, arc: 0.4, size: 0.06, birthBase: 70, life: 1.6, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: false),
        // 1 星尘：全身缓缓上升四散的星点
        VFXPreset(name: "星尘", colors: [c(1,0.92,0.6), c(1,0.82,0.45)], shape: .star, emit: .bodySphere,
                  rise: 0.28, arc: 0, size: 0.06, birthBase: 34, life: 2.4, spin: 18, stretch: 0, additive: true,
                  groundRing: false, ripples: true, notes: false),
        // 2 爱心：胸口飘散的爱心
        VFXPreset(name: "爱心", colors: [c(1,0.5,0.68), c(1,0.4,0.6)], shape: .heart, emit: .chest,
                  rise: 0.4, arc: 0.05, size: 0.1, birthBase: 10, life: 2.8, spin: 10, stretch: 0, additive: false,
                  groundRing: false, ripples: false, notes: false),
        // 3 火花：脚底上冲、重力回落的辉光火星(纯光点,靠 bloom 发光)
        VFXPreset(name: "火花", colors: [c(1,0.8,0.42), c(1,0.45,0.18)], shape: .dot, emit: .footRing,
                  rise: 1.15, arc: 0.9, size: 0.05, birthBase: 95, life: 0.95, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: false),
        // 4 星轨：双螺旋上升 + 地面涟漪 + 音符
        VFXPreset(name: "星轨", colors: [c(0.5,0.95,1), c(0.45,0.65,1)], shape: .star, emit: .spiral,
                  rise: 0.85, arc: 0.05, size: 0.05, birthBase: 70, life: 1.8, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: true),
    ]

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

final class DanceVFX {
    private weak var scene: SCNScene?
    private let root = SCNNode()
    private var ring: SCNNode?
    private var systems: [SCNParticleSystem] = []   // 主粒子(螺旋有多个),统一按节拍驱动
    private var ripplePool: [SCNNode] = []
    private var rippleIdx = 0

    private var levelProvider: (() -> Float)?
    private var link: CADisplayLink?
    private var env: Float = 0
    private var beatCooldown = 0
    private var radius: CGFloat = 0.4
    private var height: CGFloat = 1.4
    private var cur = VFXPreset.all[0]

    var preset = 0

    // MARK: 安装 / 卸载
    func install(in scene: SCNScene, feetY: Float, height h: Float, level: @escaping () -> Float) {
        remove()
        self.scene = scene
        self.levelProvider = level
        self.height = CGFloat(max(h, 1.2))
        self.radius = CGFloat(max(h * 0.3, 0.28))
        self.cur = VFXPreset.all[preset % VFXPreset.all.count]

        root.simdPosition = simd_float3(0, feetY + 0.01, 0)
        scene.rootNode.addChildNode(root)

        if cur.groundRing { buildGroundRing() }
        buildMain()
        if cur.notes { buildNotes() }
        if cur.ripples { buildRipplePool() }

        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func remove() {
        link?.invalidate(); link = nil
        root.childNodes.forEach { $0.removeFromParentNode() }
        root.removeFromParentNode()
        ring = nil; systems = []; ripplePool = []; rippleIdx = 0
    }

    /// 切换到下一个预设(循环)。
    func next() -> String {
        preset = (preset + 1) % VFXPreset.all.count
        if let sc = scene, let lv = levelProvider {
            let y = root.simdPosition.y - 0.01
            install(in: sc, feetY: y, height: Float(height), level: lv)
        }
        return VFXPreset.all[preset % VFXPreset.all.count].name
    }

    var currentName: String { VFXPreset.all[preset % VFXPreset.all.count].name }

    // MARK: 地面光环
    private func buildGroundRing() {
        let plane = SCNPlane(width: radius * 2.6, height: radius * 2.6)
        let m = plane.firstMaterial!
        m.diffuse.contents = Self.ringImage(cur.colors[1], thickness: 0.28)
        m.blendMode = .add
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.lightingModel = .constant
        let n = SCNNode(geometry: plane)
        n.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        n.renderingOrder = -2
        root.addChildNode(n)
        ring = n
        n.runAction(.repeatForever(.rotate(by: .pi * 2, around: SCNVector3(0, 0, 1), duration: 14)))
    }

    // MARK: 主粒子
    private func buildMain() {
        let ps = SCNParticleSystem()
        ps.particleImage = Self.shapeImage(cur.shape, color: cur.colors[0])
        ps.birthRate = cur.birthBase
        ps.particleLifeSpan = cur.life
        ps.particleLifeSpanVariation = cur.life * 0.4
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.particleVelocity = height * cur.rise
        ps.particleVelocityVariation = height * cur.rise * 0.4
        ps.acceleration = SCNVector3(0, -height * cur.arc, 0)
        ps.particleSize = cur.size
        ps.particleSizeVariation = cur.size * 0.6
        ps.particleAngularVelocity = cur.spin
        ps.particleAngularVelocityVariation = cur.spin
        ps.blendMode = cur.additive ? .additive : .alpha
        ps.isLightingEnabled = false
        ps.sortingMode = .none
        ps.particleColor = cur.colors[0]
        ps.particleColorVariation = SCNVector4(0.06, 0.06, 0.08, 0)
        ps.stretchFactor = cur.stretch                     // 拖尾
        // 生命周期：淡入淡出 + 先长后缩,让粒子柔和不生硬
        ps.propertyControllers = [
            .opacity: Self.fadeCtrl(),
            .size: Self.sizeCtrl(base: cur.size)
        ]

        if cur.emit == .spiral {
            // 双螺旋：两个偏移的小发射器绕 Y 自转,粒子边转边升 → 螺旋轨迹
            ps.emitterShape = SCNSphere(radius: radius * 0.08)
            ps.birthLocation = .surface
            ps.spreadingAngle = 6
            let spin = SCNNode()
            for angle in [Float(0), Float.pi] {
                let arm = SCNNode()
                arm.simdPosition = simd_float3(cos(angle) * Float(radius) * 0.9, 0, sin(angle) * Float(radius) * 0.9)
                let c = ps.copy() as! SCNParticleSystem
                arm.addParticleSystem(c)
                systems.append(c)
                spin.addChildNode(arm)
            }
            spin.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 1.6)))
            root.addChildNode(spin)
            return
        }

        let holder = SCNNode()
        switch cur.emit {
        case .footRing:
            ps.emitterShape = SCNTube(innerRadius: radius * 0.85, outerRadius: radius, height: 0.02)
            ps.birthLocation = .surface
            ps.spreadingAngle = 16
        case .bodySphere:
            ps.emitterShape = SCNSphere(radius: radius * 1.1)
            ps.birthLocation = .volume
            ps.spreadingAngle = 40
            holder.simdPosition = simd_float3(0, Float(height) * 0.5, 0)
        case .chest:
            ps.emitterShape = SCNSphere(radius: radius * 0.5)
            ps.birthLocation = .surface
            ps.spreadingAngle = 35
            holder.simdPosition = simd_float3(0, Float(height) * 0.6, 0)
        case .spiral:
            break   // 已在上面处理
        }
        holder.addParticleSystem(ps)
        root.addChildNode(holder)
        systems = [ps]
    }

    // MARK: 音符
    private func buildNotes() {
        let ps = SCNParticleSystem()
        ps.particleImage = Self.shapeImage(.note, color: UIColor(white: 1, alpha: 0.9))
        ps.birthRate = 2.2                         // 少而精,别喧宾夺主
        ps.particleLifeSpan = 2.6
        ps.particleLifeSpanVariation = 0.8
        ps.emitterShape = SCNSphere(radius: radius * 0.7)
        ps.birthLocation = .surface
        ps.emittingDirection = SCNVector3(0, 1, 0)
        ps.spreadingAngle = 22
        ps.particleVelocity = height * 0.3
        ps.particleVelocityVariation = height * 0.15
        ps.particleSize = 0.055
        ps.particleSizeVariation = 0.02
        ps.particleAngularVelocity = 30
        ps.particleAngularVelocityVariation = 40
        ps.blendMode = .alpha
        ps.isLightingEnabled = false
        ps.particleColor = .white
        ps.propertyControllers = [.opacity: Self.fadeCtrl()]   // 淡入淡出,不生硬
        let holder = SCNNode()
        holder.simdPosition = simd_float3(0, Float(height) * 0.55, 0)
        holder.addParticleSystem(ps)
        root.addChildNode(holder)
    }

    // MARK: 涟漪
    private func buildRipplePool() {
        for _ in 0..<4 {
            let plane = SCNPlane(width: radius * 2, height: radius * 2)
            let m = plane.firstMaterial!
            m.diffuse.contents = Self.ringImage(cur.colors[0], thickness: 0.08)
            m.blendMode = .add
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            m.lightingModel = .constant
            let n = SCNNode(geometry: plane)
            n.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            n.opacity = 0
            n.renderingOrder = -1
            root.addChildNode(n)
            ripplePool.append(n)
        }
    }

    private func fireRipple(intensity: Float) {
        guard !ripplePool.isEmpty else { return }
        let n = ripplePool[rippleIdx % ripplePool.count]; rippleIdx += 1
        n.removeAllActions()
        n.simdScale = simd_float3(repeating: 0.4)
        n.opacity = CGFloat(0.5 + intensity * 0.5)
        let grow = SCNAction.scale(to: CGFloat(2.4 + intensity * 1.4), duration: 0.9); grow.timingMode = .easeOut
        let fade = SCNAction.fadeOut(duration: 0.9)
        n.runAction(.group([grow, fade]))
    }

    // MARK: 每帧驱动
    @objc private func tick() {
        let level = levelProvider?() ?? 0
        env = env * 0.82 + level * 0.18
        if let ring = ring {
            let s = 1.0 + CGFloat(level) * 0.35
            ring.simdScale = simd_float3(Float(s), Float(s), 1)
            ring.opacity = CGFloat(0.35 + level * 0.55)
        }
        let rate = cur.birthBase * CGFloat(0.6 + level * 1.1)   // 安静时也有基础量
        for s in systems { s.birthRate = rate }
        if beatCooldown > 0 { beatCooldown -= 1 }
        if cur.ripples, level > env * 1.28, level > 0.18, beatCooldown == 0 {
            fireRipple(intensity: level)
            beatCooldown = 12
        }
    }

    // MARK: 贴图
    private static func shapeImage(_ shape: VFXPreset.Shape, color: UIColor) -> UIImage {
        switch shape {
        case .dot:   return dotImage(color)
        case .star:  return glyphImage("✦", color)
        case .heart: return glyphImage("❤", color)
        case .note:  return glyphImage(["♪","♫","♬"].randomElement()!, color)
        case .spark: return sparkImage(color)
        }
    }

    /// 柔和发光点：亮白核心 → 彩色晕 → 极柔透明边(加法混合下像真实光点)。
    private static func dotImage(_ color: UIColor) -> UIImage {
        let s = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cols = [UIColor.white.cgColor,
                        color.withAlphaComponent(0.85).cgColor,
                        color.withAlphaComponent(0.25).cgColor,
                        color.withAlphaComponent(0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray,
                               locations: [0, 0.28, 0.6, 1])!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 48, y: 48), startRadius: 0,
                                             endCenter: CGPoint(x: 48, y: 48), endRadius: 48, options: [])
        }
    }

    /// 淡入淡出(opacity 随粒子寿命 0→1→0)。
    private static func fadeCtrl() -> SCNParticlePropertyController {
        let a = CAKeyframeAnimation()
        a.values = [0.0, 1.0, 0.9, 0.0]
        a.keyTimes = [0.0, 0.2, 0.6, 1.0]
        return SCNParticlePropertyController(animation: a)
    }

    /// 大小曲线(出生小 → 展开 → 消散前缩小)。
    private static func sizeCtrl(base: CGFloat) -> SCNParticlePropertyController {
        let a = CAKeyframeAnimation()
        a.values = [base * 0.4, base, base * 0.15]
        a.keyTimes = [0.0, 0.35, 1.0]
        return SCNParticlePropertyController(animation: a)
    }

    private static func sparkImage(_ color: UIColor) -> UIImage {
        let s = CGSize(width: 32, height: 96)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let cols = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(g, start: CGPoint(x: 16, y: 0), end: CGPoint(x: 16, y: 96), options: [])
        }
    }

    private static func glyphImage(_ str: String, _ color: UIColor) -> UIImage {
        let s = CGSize(width: 72, height: 72)
        return UIGraphicsImageRenderer(size: s).image { _ in
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 52, weight: .bold),
                .foregroundColor: color, .paragraphStyle: p]
            (str as NSString).draw(in: CGRect(x: 0, y: 6, width: 72, height: 60), withAttributes: attrs)
        }
    }

    /// 彩色发光圆环：内透明 → 彩色 → 外透明。thickness 越小环越细。
    private static func ringImage(_ color: UIColor, thickness: CGFloat) -> UIImage {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let peak: CGFloat = 0.82
            let cols = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
            let locs: [CGFloat] = [max(0, peak - thickness), peak, min(1, peak + thickness)]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cols as CFArray, locations: locs)!
            ctx.cgContext.drawRadialGradient(g, startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                                             endCenter: CGPoint(x: 128, y: 128), endRadius: 128, options: [])
        }
    }
}
