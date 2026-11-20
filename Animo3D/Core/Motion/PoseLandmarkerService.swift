//
//  PoseLandmarkerService.swift
//  Animo3D
//
//  Wraps MediaPipe BlazePose (Heavy) pose detection.
//

import Foundation
import MediaPipeTasksVision
import CoreVideo
import UIKit
import simd

// VideoPoseViewModel waits for initialization and permits only one inference at a time.
nonisolated final class PoseLandmarkerService: @unchecked Sendable {

    private let landmarker: PoseLandmarker

    init() throws {
        guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_heavy",
                                               ofType: "task") else {
            throw NSError(domain: "PoseLandmarkerService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "pose_landmarker_heavy.task model file not found"])
        }

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video          // Per-frame video mode (with timestamps)
        options.numPoses = 1                   // Single person; raise this for multiple people
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5

        self.landmarker = try PoseLandmarker(options: options)
    }

    /// Runs detection on one pixel buffer. timestampMs must increase monotonically.
    func detect(pixelBuffer: CVPixelBuffer,
                orientation: UIImage.Orientation,
                timestampMs: Int) -> PoseFrameResult? {
        guard let image = try? MPImage(pixelBuffer: pixelBuffer, orientation: orientation) else {
            return nil
        }
        guard let result = try? landmarker.detect(videoFrame: image,
                                                   timestampInMilliseconds: timestampMs) else {
            return nil
        }
        return PoseFrameResult(
            normalized: result.landmarks.map { person in
                person.map {
                    NormalizedLandmarkLite(
                        x: CGFloat($0.x),
                        y: CGFloat($0.y),
                        visibility: $0.visibility?.floatValue ?? 1
                    )
                }
            },
            world: result.worldLandmarks.map { person in
                person.map { simd_float3(Float($0.x), Float($0.y), Float($0.z)) }
            }
        )
    }
}
