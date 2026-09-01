//
//  DanceVFX.swift
//  Animo3D
//
//  Stage VFX: several switchable particle presets (halo / stardust / hearts / sparks / star trail),
//  each pulsing with the music's live energy (MusicController.currentLevel).
//  Generated purely in code (particle systems + textures), attached to the character scene's root node, shared by screen and AR.
//

import SceneKit
import UIKit
import QuartzCore

/// Configuration for one VFX preset.
struct VFXPreset {
    let name: String
    let colors: [UIColor]        // [particle main color, ring/ripple color]
    let shape: Shape             // Particle shape texture
    let emit: Emit               // Emission mode
    let rise: CGFloat            // Rise speed factor (x body height)
    let arc: CGFloat             // Fall-back gravity factor (0 = straight up, >0 = arc)
    let size: CGFloat
    let birthBase: CGFloat       // Base birth rate
    let life: CGFloat            // Particle lifetime (seconds); shorter means a smaller trail and range
    let spin: CGFloat            // Particle spin
    let stretch: CGFloat         // Stretch along the direction of motion (0 = no trail)
    let additive: Bool
    let groundRing: Bool
    let ripples: Bool
    let notes: Bool

    enum Shape { case dot, star, heart, spark, note }
    enum Emit { case footRing, bodySphere, chest, spiral }   // Foot ring / whole-body sphere / chest / rising spiral

    static let all: [VFXPreset] = [
        // 0 Halo: soft light particles shooting up from a ring at the feet, gathering into a hemispherical halo
        VFXPreset(name: "Halo", colors: [c(0.45,0.8,1), c(0.6,0.5,1)], shape: .dot, emit: .footRing,
                  rise: 0.9, arc: 0.4, size: 0.06, birthBase: 70, life: 1.6, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: false),
        // 1 Stardust: star points slowly rising and scattering off the whole body
        VFXPreset(name: "Stardust", colors: [c(1,0.92,0.6), c(1,0.82,0.45)], shape: .star, emit: .bodySphere,
                  rise: 0.28, arc: 0, size: 0.06, birthBase: 34, life: 2.4, spin: 18, stretch: 0, additive: true,
                  groundRing: false, ripples: true, notes: false),
        // 2 Hearts: hearts drifting away from the chest
        VFXPreset(name: "Hearts", colors: [c(1,0.5,0.68), c(1,0.4,0.6)], shape: .heart, emit: .chest,
                  rise: 0.4, arc: 0.05, size: 0.1, birthBase: 10, life: 2.8, spin: 10, stretch: 0, additive: false,
                  groundRing: false, ripples: false, notes: false),
        // 3 Sparks: glowing embers shooting up from the feet and falling back under gravity (pure light points, the glow comes from bloom)
        VFXPreset(name: "Sparks", colors: [c(1,0.8,0.42), c(1,0.45,0.18)], shape: .dot, emit: .footRing,
                  rise: 1.15, arc: 0.9, size: 0.05, birthBase: 95, life: 0.95, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: false),
        // 4 Star trail: rising double spiral + ground ripple + music notes
        VFXPreset(name: "Star Trail", colors: [c(0.5,0.95,1), c(0.45,0.65,1)], shape: .star, emit: .spiral,
                  rise: 0.85, arc: 0.05, size: 0.05, birthBase: 70, life: 1.8, spin: 0, stretch: 0, additive: true,
                  groundRing: true, ripples: true, notes: true),
    ]

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

final class DanceVFX {
    /// The node the effects hang under. On the screen stage that is the scene root; in AR it is the
    /// placed character's container, so the particles ride with the anchor and inherit its scale.
    /// Installing into a *scene* was the bug: in AR the character is moved into ARSCNView's own
    /// scene, so effects added to the controller's scene were never rendered at all.
    private weak var parent: SCNNode?
    private let root = SCNNode()
    private var ring: SCNNode?
    private var systems: [SCNParticleSystem] = []   // Main particles (the spiral has several), all driven by the beat
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

    // MARK: Install / uninstall
    func install(in parent: SCNNode, feetY: Float, height h: Float, level: @escaping () -> Float) {
        remove()
        self.parent = parent
        self.levelProvider = level
        self.height = CGFloat(max(h, 1.2))
        self.radius = CGFloat(max(h * 0.3, 0.28))
        self.cur = VFXPreset.all[preset % VFXPreset.all.count]

        root.simdPosition = simd_float3(0, feetY + 0.01, 0)
        parent.addChildNode(root)

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

    /// Switch to the next preset (wrapping around).
    func next() -> String {
        preset = (preset + 1) % VFXPreset.all.count
        if let p = parent, let lv = levelProvider {
            let y = root.simdPosition.y - 0.01
            install(in: p, feetY: y, height: Float(height), level: lv)
        }
        return VFXPreset.all[preset % VFXPreset.all.count].name
    }

    var currentName: String { VFXPreset.all[preset % VFXPreset.all.count].name }

    // MARK: Ground halo
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

    // MARK: Main particles
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
        ps.stretchFactor = cur.stretch                     // Trail
        // Lifecycle: fade in and out, grow then shrink, so particles look soft rather than abrupt
        ps.propertyControllers = [
            .opacity: Self.fadeCtrl(),
            .size: Self.sizeCtrl(base: cur.size)
        ]

        if cur.emit == .spiral {
            // Double spiral: two offset emitters spinning around Y, particles rise while rotating -> spiral trails
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
            break   // Already handled above
        }
        holder.addParticleSystem(ps)
        root.addChildNode(holder)
        systems = [ps]
    }

    // MARK: Music notes
    private func buildNotes() {
        let ps = SCNParticleSystem()
        ps.particleImage = Self.shapeImage(.note, color: UIColor(white: 1, alpha: 0.9))
        ps.birthRate = 2.2                         // Few but well placed, they should not steal the show
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
        ps.propertyControllers = [.opacity: Self.fadeCtrl()]   // Fade in and out, not abrupt
        let holder = SCNNode()
        holder.simdPosition = simd_float3(0, Float(height) * 0.55, 0)
        holder.addParticleSystem(ps)
        root.addChildNode(holder)
    }

    // MARK: Ripple
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

    // MARK: Per-frame drive
    @objc private func tick() {
        let level = levelProvider?() ?? 0
        env = env * 0.82 + level * 0.18
        if let ring = ring {
            let s = 1.0 + CGFloat(level) * 0.35
            ring.simdScale = simd_float3(Float(s), Float(s), 1)
            ring.opacity = CGFloat(0.35 + level * 0.55)
        }
        let rate = cur.birthBase * CGFloat(0.6 + level * 1.1)   // Keep a base amount even when it is quiet
        for s in systems { s.birthRate = rate * DeviceTier.particleScale }   // Lower the density on low-end devices
        if beatCooldown > 0 { beatCooldown -= 1 }
        if cur.ripples, level > env * 1.28, level > 0.18, beatCooldown == 0 {
            fireRipple(intensity: level)
            beatCooldown = 12
        }
    }

    // MARK: Textures
    private static func shapeImage(_ shape: VFXPreset.Shape, color: UIColor) -> UIImage {
        switch shape {
        case .dot:   return dotImage(color)
        case .star:  return glyphImage("✦", color)
        case .heart: return glyphImage("❤", color)
        case .note:  return glyphImage(["♪","♫","♬"].randomElement()!, color)
        case .spark: return sparkImage(color)
        }
    }

    /// Soft glowing dot: bright white core -> colored halo -> very soft transparent edge (looks like a real light point under additive blending).
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

    /// Fade in and out (opacity follows the particle lifetime 0 -> 1 -> 0).
    private static func fadeCtrl() -> SCNParticlePropertyController {
        let a = CAKeyframeAnimation()
        a.values = [0.0, 1.0, 0.9, 0.0]
        a.keyTimes = [0.0, 0.2, 0.6, 1.0]
        return SCNParticlePropertyController(animation: a)
    }

    /// Size curve (born small -> expands -> shrinks before dying).
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

    /// Colored glowing ring: transparent inside -> color -> transparent outside. A smaller thickness makes a thinner ring.
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
