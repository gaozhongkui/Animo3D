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

/// Detection result for one frame: use normalized (0-1) to draw points on screen, and world (meters) for 3D motion.
struct PoseFrameResult {
    /// Normalized 2D coordinates (relative to the image), used for the overlay drawing. Each element = one person's 33 points.
    let normalized: [[NormalizedLandmark]]
    /// 3D world coordinates (in meters, with the hip center as the origin), used to drive the 3D model.
    let world: [[Landmark]]
}

final class PoseLandmarkerService {

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
        return PoseFrameResult(normalized: result.landmarks, world: result.worldLandmarks)
    }
}
