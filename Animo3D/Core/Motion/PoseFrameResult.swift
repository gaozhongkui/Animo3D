import CoreGraphics
import simd

/// Values crossing from inference to the UI contain no mutable MediaPipe objects.
nonisolated struct PoseFrameResult: Sendable {
    let normalized: [[NormalizedLandmarkLite]]
    let world: [[simd_float3]]
}

nonisolated struct NormalizedLandmarkLite: Sendable {
    let x: CGFloat
    let y: CGFloat
    let visibility: Float
}
