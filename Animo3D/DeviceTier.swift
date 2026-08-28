//
//  DeviceTier.swift
//  Animo3D
//
//  Device performance tiers: low-end devices (RAM < 4GB, roughly iPhone X/XR/SE and older) automatically scale heavy effects down,
//  turning off the bloom post-process, lowering particle density and antialiasing, to avoid stutter.
//

import Foundation
import SceneKit

enum DeviceTier {
    /// Physical memory < 4GB counts as low-end (A11 and earlier, or low-spec).
    static let isLowEnd: Bool = ProcessInfo.processInfo.physicalMemory < UInt64(4) * 1024 * 1024 * 1024

    /// Bloom glow intensity: off (0) on low-end, 1.1 on high-end.
    static var bloomIntensity: CGFloat { isLowEnd ? 0 : 1.1 }

    /// Particle birth-rate factor: 0.45 on low-end, 1.0 on high-end.
    static var particleScale: CGFloat { isLowEnd ? 0.45 : 1.0 }

    /// Antialiasing for the live/performance views: off on low-end, 2x on high-end (4x is too heavy, so it is unused).
    static var antialiasing: SCNAntialiasingMode { isLowEnd ? .none : .multisampling2X }

    /// Antialiasing for offscreen thumbnail rendering.
    static var thumbAntialiasing: SCNAntialiasingMode { isLowEnd ? .none : .multisampling2X }

    /// Low-end devices do not run "live dancing" (LiveDanceView) on the dance selection cards; a static pose image is used instead.
    static var allowsLiveDanceCards: Bool { !isLowEnd }

    /// Live stage floor reflection: off on low-end. A reflection renders the whole scene one extra time, so like shadows it is a major cost.
    static var floorReflectivity: CGFloat { isLowEnd ? 0 : 0.16 }

    /// Floor reflection strength in sky mode (sky mode relies on the reflection alone, so low-end lowers it rather than turning it off).
    static var skyFloorReflectivity: CGFloat { isLowEnd ? 0 : 0.5 }

    /// Real-time soft shadows from the directional light: off on low-end, since the contact shadow texture under the feet already sells the grounding.
    static var dynamicShadows: Bool { !isLowEnd }

    /// Soft shadow sample count: the previous fixed 16 was too heavy (forward mode runs a shadow pass every frame).
    static var shadowSampleCount: Int { isLowEnd ? 4 : 8 }

    /// Skeletal playback frame rate: the mocap source is 30fps anyway, so there is no need to re-skin at 60Hz.
    static var playbackFPS: Int { 30 }
}
