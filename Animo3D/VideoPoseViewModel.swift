//
//  VideoPoseViewModel.swift
//  Animo3D
//
//  Plays the selected video, pulls frames live with a DisplayLink to feed BlazePose, and publishes the detection results.
//

import Foundation
import AVFoundation
import UIKit
import Combine
import simd
import MediaPipeTasksVision

@MainActor
final class VideoPoseViewModel: ObservableObject {

    /// Normalized landmarks of the latest frame (first person).
    @Published var landmarks: [NormalizedLandmarkLite] = []
    /// Status message.
    @Published var status: String = L("Select a video")
    /// Whether processing is in progress.
    @Published var isRunning = false

    /// The 33 3D world coordinates (meters) of each frame, used to drive the 3D model. Called back on the main thread.
    var onWorld: (([simd_float3]) -> Void)?

    let player = AVPlayer()

    private var service: PoseLandmarkerService?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var orientation: UIImage.Orientation = .up
    // MediaPipe's video mode requires strictly increasing timestamps. Looping the video rewinds the playback time to 0,
    // so playback time cannot be used as the timestamp directly - after one loop it would never grow again and detection would stall completely.
    // Instead a separate monotonic counter is used, incremented by 33ms (~30fps) per processed frame, so it always increases.
    private var monotonicMs: Int = 0

    init() {
        do {
            service = try PoseLandmarkerService()
        } catch {
            status = String(format: L("Failed to load model: %@"), error.localizedDescription)
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

        // Loop playback, which makes repeated observation easier
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        startDisplayLink()
        player.play()
        isRunning = true
        status = L("Detecting… (BlazePose Heavy)")
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

        // Monotonically increasing timestamp: hasNewPixelBuffer already guarantees a new frame, so all that is needed here is a timestamp that keeps growing,
        // which keeps increasing across video loops (otherwise MediaPipe rejects it after the rewind to 0 and the drive stalls).
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

        // 3D world coordinates -> drive the model
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

    /// Infers the image orientation fed to MediaPipe from the video track's preferredTransform.
    private static func orientation(for asset: AVAsset) async -> UIImage.Orientation {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let transform = try? await track.load(.preferredTransform) else {
            return .up
        }
        let a = transform.a, b = transform.b, c = transform.c, d = transform.d
        if a == 1 && d == 1 { return .up }
        if a == -1 && d == -1 { return .down }
        if b == 1 && c == -1 { return .right }   // Clockwise 90 degrees (common for portrait)
        if b == -1 && c == 1 { return .left }     // Counter-clockwise 90 degrees
        return .up
    }
}

/// Lightweight struct that keeps MediaPipe types from leaking into the SwiftUI view layer.
struct NormalizedLandmarkLite {
    let x: CGFloat
    let y: CGFloat
    let visibility: Float
}
