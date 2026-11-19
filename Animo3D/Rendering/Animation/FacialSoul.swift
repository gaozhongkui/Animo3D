//
//  FacialSoul.swift
//  Animo3D
//
//  Gives the character a "soul" through automatic micro-interactions:
//  - Automatic blinking: Randomly closes and opens eyes.
//  - Subtle head drift: Avoids the "frozen" look by adding tiny, natural head movements.
//

import SceneKit
import simd

final class FacialSoul {
    private weak var characterRoot: SCNNode?
    private weak var headNode: SCNNode?

    private var nextBlinkTime: TimeInterval = 0
    private var blinkProgress: Float = 0
    private var isBlinking = false

    private var seedTime = Double.random(in: 0...1000)

    // Cache for morpher targets
    private struct MorpherTarget {
        let morpher: SCNMorpher
        let index: Int
    }
    private var blinkTargets: [MorpherTarget] = []
    private var searchAttempts = 0

    init(rootNode: SCNNode?, headNode: SCNNode?) {
        self.characterRoot = rootNode
        self.headNode = headNode
    }

    func update(at time: TimeInterval) {
        updateBlink(at: time)
        updateHeadDrift(at: time)
    }

    private func updateBlink(at time: TimeInterval) {
        // Keep searching for the first 30 frames to be absolutely sure we catch everything
        if searchAttempts < 30 {
            findBlinkMorphers()
            searchAttempts += 1
            if !blinkTargets.isEmpty && nextBlinkTime == 0 {
                nextBlinkTime = time + 0.2
            }
        }

        if isBlinking {
            blinkProgress += 0.25 // Fast blink
            if blinkProgress >= 1.0 {
                isBlinking = false
                blinkProgress = 0
                nextBlinkTime = time + Double.random(in: 1.5...4.5)
            }
        } else if time >= nextBlinkTime {
            if !blinkTargets.isEmpty {
                isBlinking = true
                blinkProgress = 0
            } else {
                nextBlinkTime = time + 2.0
            }
        }

        // Triangle wave for blink: 0 -> 1 -> 0
        let value = isBlinking ? (blinkProgress < 0.5 ? (blinkProgress * 2) : (2 - blinkProgress * 2)) : 0

        // Apply to all found morpher targets
        for target in blinkTargets {
            target.morpher.setWeight(CGFloat(value), forTargetAt: target.index)
        }
    }

    private func findBlinkMorphers() {
        guard let root = characterRoot else { return }

        // We clear and re-search during the searchAttempts phase to catch nodes added late
        blinkTargets.removeAll()

        root.enumerateHierarchy { node, _ in
            guard let morpher = node.morpher else { return }

            for i in 0..<morpher.targets.count {
                let name = (morpher.targets[i].name ?? "").lowercased()

                // Extremely aggressive matching for all kinds of 3D models
                let isBlink = name.contains("blink")
                           || name.contains("eye_close")
                           || name.contains("eyeclose")
                           || name.contains("close_eye")
                           || name.contains("mabataki")
                           || name.contains("fcl_eye_close")
                           || name.contains("closeeye")
                           || (name.contains("eye") && (name.contains("close") || name.contains("cls") || name.contains("smi")))

                // Exclude obvious non-blink expressions
                let isExcluded = name.contains("joy") || name.contains("angry") || name.contains("fun")
                              || name.contains("look") || name.contains("up") || name.contains("down")
                              || name.contains("wide") || name.contains("open")

                if isBlink && !isExcluded {
                    blinkTargets.append(MorpherTarget(morpher: morpher, index: i))
                }
            }
        }
    }

    private func updateHeadDrift(at time: TimeInterval) {
        guard let head = headNode else { return }

        // Subtle slow drift using noise-like sine waves
        let t = time + seedTime
        // Slightly larger to make it noticeable during testing
        let pitch = Float(sin(t * 0.8) * 0.012)
        let yaw = Float(sin(t * 0.6) * 0.015)
        let roll = Float(sin(t * 0.4) * 0.008)

        let qPitch = simd_quatf(angle: pitch, axis: simd_float3(1, 0, 0))
        let qYaw = simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
        let qRoll = simd_quatf(angle: roll, axis: simd_float3(0, 0, 1))

        head.simdOrientation = head.simdOrientation * qYaw * qPitch * qRoll
    }
}
