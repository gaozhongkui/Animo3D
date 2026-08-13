//
//  VideoPoseViewModel.swift
//  Animo3D
//
//  播放选中的视频，用 DisplayLink 实时拉帧喂给 BlazePose，发布检测结果。
//

import Foundation
import AVFoundation
import UIKit
import Combine
import simd
import MediaPipeTasksVision

@MainActor
final class VideoPoseViewModel: ObservableObject {

    /// 最新一帧的归一化关节点（第一个人）。
    @Published var landmarks: [NormalizedLandmarkLite] = []
    /// 状态提示。
    @Published var status: String = "请选择一个视频"
    /// 是否正在处理。
    @Published var isRunning = false

    /// 每帧的 33 个 3D 世界坐标（米），用于驱动 3D 模型。主线程回调。
    var onWorld: (([simd_float3]) -> Void)?

    let player = AVPlayer()

    private var service: PoseLandmarkerService?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var orientation: UIImage.Orientation = .up
    // MediaPipe 视频模式要求时间戳严格递增。视频循环会把播放时间拨回 0，
    // 不能直接用播放时间当时间戳，否则循环一次后时间戳永远不再增大、检测彻底停摆。
    // 改用独立的单调计数器，每处理一帧 +33ms（~30fps），永远递增。
    private var monotonicMs: Int = 0

    init() {
        do {
            service = try PoseLandmarkerService()
        } catch {
            status = "模型加载失败: \(error.localizedDescription)"
        }
    }

    func load(url: URL) {
        Task { await setupPlayer(url: url) }
    }

    private func setupPlayer(url: URL) async {
        let asset = AVURLAsset(url: url)
        orientation = await Self.orientation(for: asset)

        let item = AVPlayerItem(asset: asset)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        videoOutput = output

        player.replaceCurrentItem(with: item)

        // 循环播放，方便反复观察
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        startDisplayLink()
        player.play()
        isRunning = true
        status = "检测中… (BlazePose Heavy)"
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(onFrame))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onFrame() {
        guard let output = videoOutput, let service else { return }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time,
                                                       itemTimeForDisplay: nil) else { return }

        // 单调递增时间戳：hasNewPixelBuffer 已保证是新帧，这里只需喂一个永远变大的时间戳，
        // 使其跨视频循环仍然递增（避免循环回 0 后被 MediaPipe 拒绝、驱动停摆）。
        monotonicMs += 33

        guard let result = service.detect(pixelBuffer: pixelBuffer,
                                          orientation: orientation,
                                          timestampMs: monotonicMs) else { return }

        if let first = result.normalized.first {
            landmarks = first.map {
                NormalizedLandmarkLite(x: CGFloat($0.x),
                                       y: CGFloat($0.y),
                                       visibility: $0.visibility?.floatValue ?? 1)
            }
        } else {
            landmarks = []
        }

        // 3D 世界坐标 → 驱动模型
        if let firstWorld = result.world.first {
            let pts = firstWorld.map { simd_float3(Float($0.x), Float($0.y), Float($0.z)) }
            onWorld?(pts)
        }
    }

    func stop() {
        player.pause()
        displayLink?.invalidate()
        displayLink = nil
        isRunning = false
    }

    /// 根据视频轨道 preferredTransform 推断喂给 MediaPipe 的图像方向。
    private static func orientation(for asset: AVAsset) async -> UIImage.Orientation {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform) else {
            return .up
        }
        let a = transform.a, b = transform.b, c = transform.c, d = transform.d
        if a == 1 && d == 1 { return .up }
        if a == -1 && d == -1 { return .down }
        if b == 1 && c == -1 { return .right }   // 顺时针 90°（竖屏常见）
        if b == -1 && c == 1 { return .left }     // 逆时针 90°
        return .up
    }
}

/// 轻量结构，避免把 MediaPipe 类型泄漏到 SwiftUI 视图层。
struct NormalizedLandmarkLite {
    let x: CGFloat
    let y: CGFloat
    let visibility: Float
}
