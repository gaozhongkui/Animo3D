//
//  SpringBoneSolver.swift
//  Animo3D
//
//  Secondary bone (hair, skirt, sleeves, bust) physics simulation for 3D character models.
//

import SceneKit
import simd
import QuartzCore

/// One link of a secondary bone chain, simulated as a single particle sitting at the bone's tail.
struct SpringBone {
    let node: SCNNode
    /// Where the tail sits in the bone's own space: the next link's position, so the chain
    /// uses the model's real segment lengths instead of one guessed constant.
    let localTail: simd_float3
    /// The bone's orientation in its parent's space with no physics applied. Every frame
    /// restarts from here, so the solver reads the pose the animation asks for and writes a
    /// delta on top of it; integrating on its own output instead lets the chain drift away.
    let restLocalRotation: simd_quatf
    var current: simd_float3
    var prev: simd_float3
}

/// Bounding sphere for collision detection with hair particles.
struct SpringCollider {
    let node: SCNNode
    let radius: Float // Base radius at scale 1.0
}

final class SpringBoneSolver {
    static let secondaryBonePrefix = "J_Sec_"

    private var springBones: [SpringBone] = []
    private var colliders: [SpringCollider] = []
    private var windPhase: Float = 0
    /// `seed()` rebuilds the chains on the main thread while `update()` walks them on
    /// SceneKit's render thread - switching character mid-frame used to be a crash window.
    private let springLock = NSLock()

    func tearDown() {
        springLock.lock()
        springBones.removeAll()
        springLock.unlock()
        colliders.removeAll()
    }

    /// Set up bounding spheres for collision detection based on the character's dimensions.
    func setupColliders(modelHeight: Float, humanoidNode: (String) -> SCNNode?) {
        colliders.removeAll()
        let h = max(modelHeight, 0.1)

        func add(_ bone: String, radius: Float) {
            if let node = humanoidNode(bone) {
                colliders.append(SpringCollider(node: node, radius: radius * h))
            }
        }

        // Head and shoulders are the primary points hair interacts with.
        add("head", radius: 0.12)
        add("leftShoulder", radius: 0.08)
        add("rightShoulder", radius: 0.08)
        // Upper torso to prevent long hair from sinking into the chest/back.
        add("upperChest", radius: 0.15)
        if humanoidNode("upperChest") == nil {
            add("chest", radius: 0.15)
        }
        if humanoidNode("upperChest") == nil && humanoidNode("chest") == nil {
            add("spine", radius: 0.15)
        }
    }

    /// Build the secondary bone chains from the nodes provided.
    func seedSecondaryPhysics(_ nodes: [SCNNode]) {
        var bones: [SpringBone] = []
        bones.reserveCapacity(nodes.count)

        for node in nodes {
            guard let tip = node.childNodes.first(where: {
                ($0.name ?? "").hasPrefix(Self.secondaryBonePrefix)
            }) else { continue }
            let localTail = tip.simdPosition
            guard simd_length_squared(localTail) > 1e-8 else { continue }

            let tail = node.simdConvertPosition(localTail, to: nil)
            bones.append(SpringBone(node: node,
                                    localTail: localTail,
                                    restLocalRotation: node.simdOrientation,
                                    current: tail,
                                    prev: tail))
        }

        // Parents first: a link solves against its parent's transform for *this* frame.
        bones.sort { depth(of: $0.node) < depth(of: $1.node) }

        springLock.lock()
        springBones = bones
        springLock.unlock()
    }

    private func depth(of node: SCNNode) -> Int {
        var d = 0
        var n = node.parent
        while let p = n { d += 1; n = p.parent }
        return d
    }

    /// Step the secondary bone chains. Runs on SceneKit's render thread.
    func updatePhysics(isLoaded: Bool, isSceneActive: Bool, vrmNode: SCNNode?, facialSoul: FacialSoul?, userScale: Float) {
        guard isLoaded, isSceneActive else { return }
        let t = CACurrentMediaTime()

        // 1. For VRM models, let the library update bone physics/springs first.
        if let vrm = vrmNode {
            VRMCharacter.step(vrm, at: t)
        }

        // 2. Inject "soul" (blinking/head drift) for all models.
        facialSoul?.update(at: t)

        // 3. Bundled models (Mixamo) use our own spring solver for secondary movement.
        if vrmNode != nil { return }

        windPhase += 0.05
        let wind = simd_float3(sin(windPhase) * 0.008, 0, cos(windPhase * 0.7) * 0.008) * userScale

        springLock.lock()
        defer { springLock.unlock() }
        guard !springBones.isEmpty else { return }

        let stiffness: Float = 0.16     // how hard a link is pulled back to the animated pose
        let drag: Float = 0.75          // share of velocity kept each frame
        let sag: Float = 0.015          // gravity, as a fraction of the link's own length

        for i in springBones.indices {
            let node = springBones[i].node
            guard node.parent != nil else { continue }

            node.simdOrientation = springBones[i].restLocalRotation
            let origin = node.simdWorldPosition
            let restTail = node.simdConvertPosition(springBones[i].localTail, to: nil)
            let length = simd_length(restTail - origin)
            guard length > 1e-5 else { continue }

            if simd_distance(springBones[i].current, origin) > length * 6 {
                springBones[i].current = restTail
                springBones[i].prev = restTail
            }

            let velocity = (springBones[i].current - springBones[i].prev) * drag
            let pull = (restTail - springBones[i].current) * stiffness
            var next = springBones[i].current + velocity + pull + simd_float3(0, -sag * length, 0) + wind

            for collider in colliders {
                let center = collider.node.simdWorldPosition
                let r = collider.radius * userScale
                let dist = simd_distance(next, center)
                if dist < r {
                    let dir = simd_normalize(next - center)
                    next = center + dir * r
                }
            }

            let dir = next - origin
            guard simd_length_squared(dir) > 1e-10 else { continue }
            next = origin + simd_normalize(dir) * length

            springBones[i].prev = springBones[i].current
            springBones[i].current = next

            let from = simd_normalize(restTail - origin)
            let to = simd_normalize(next - origin)
            let d = simd_dot(from, to)
            guard d < 0.99999, d > -0.99999 else { continue }
            node.simdWorldOrientation = simd_quatf(from: from, to: to) * node.simdWorldOrientation
        }
    }
}
