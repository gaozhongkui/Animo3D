//
//  PoseLandmarkerService.swift
//  Animo3D
//
//  封装 MediaPipe BlazePose (Heavy) 姿态检测。
//

import Foundation
import MediaPipeTasksVision
import CoreVideo
import UIKit

/// 一帧的检测结果：屏幕上画点用 normalized（0~1），做 3D 动作用 world（米）。
struct PoseFrameResult {
    /// 归一化 2D 坐标（相对图像），用于叠加绘制。每个元素 = 一个人的 33 个点。
    let normalized: [[NormalizedLandmark]]
    /// 3D 世界坐标（单位米，以髋部中心为原点），用于驱动 3D 模型。
    let world: [[Landmark]]
}

final class PoseLandmarkerService {

    private let landmarker: PoseLandmarker

    init() throws {
        guard let modelPath = Bundle.main.path(forResource: "pose_landmarker_heavy",
                                               ofType: "task") else {
            throw NSError(domain: "PoseLandmarkerService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 pose_landmarker_heavy.task 模型文件"])
        }

        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .video          // 视频逐帧模式（带时间戳）
        options.numPoses = 1                   // 单人；要多人调大
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5

        self.landmarker = try PoseLandmarker(options: options)
    }

    /// 对一帧像素缓冲做检测。timestampMs 必须单调递增。
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
