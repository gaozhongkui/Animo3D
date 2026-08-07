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
import MediaPipeTasksVision

@MainActor
final class VideoPoseViewModel: ObservableObject {

    /// 最新一帧的归一化关节点（第一个人）。
    @Published var landmarks: [NormalizedLandmarkLite] = []
    /// 状态提示。
    @Published var status: String = "请选择一个视频"
    /// 是否正在处理。
    @Published var isRunning = false

    let player = AVPlayer()

    private var service: PoseLandmarkerService?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var orientation: UIImage.Orientation = .up
    private var lastTimestampMs: Int = -1

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

        let ms = Int(CMTimeGetSeconds(time) * 1000)
        guard ms > lastTimestampMs else { return }   // 时间戳必须递增
        lastTimestampMs = ms

        guard let result = service.detect(pixelBuffer: pixelBuffer,
                                          orientation: orientation,
                                          timestampMs: ms) else { return }

        if let first = result.normalized.first {
            landmarks = first.map {
                NormalizedLandmarkLite(x: CGFloat($0.x),
                                       y: CGFloat($0.y),
                                       visibility: $0.visibility?.floatValue ?? 1)
            }
        } else {
            landmarks = []
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
