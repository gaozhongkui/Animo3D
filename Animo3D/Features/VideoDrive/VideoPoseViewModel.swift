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

@MainActor
final class VideoPoseViewModel: ObservableObject {

    /// Normalized landmarks of the latest frame (first person).
    @Published var landmarks: [NormalizedLandmarkLite] = []
    /// Status message.
    /// Starts on the model-loading message rather than "Select a video": the model now loads in the
    /// background, and a user who picks a clip in that first second would otherwise watch a
    /// motionless character with nothing on screen explaining why.
    @Published var status: String = L("Preparing motion analysis...")
    /// Whether processing is in progress.
    @Published var isRunning = false

    /// The 33 3D world coordinates (meters) of each frame, used to drive the 3D model. Called back on the main thread.
    var onWorld: (([simd_float3]) -> Void)?

    let player = AVPlayer()

    private var service: PoseLandmarkerService?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var playerObserverToken: NSObjectProtocol?
    private var orientation: UIImage.Orientation = .up
    // MediaPipe's video mode requires strictly increasing timestamps. Looping the video rewinds the playback time to 0,
    // so playback time cannot be used as the timestamp directly - after one loop it would never grow again and detection would stall completely.
    // Instead a separate monotonic counter is used, incremented by 33ms (~30fps) per processed frame, so it always increases.
    private var monotonicMs: Int = 0
    /// 核心处理锁：确保重型 AI 推理不会在后台堆积，保护主线程绝对流畅
    private var isProcessing = false

    /// True once the pose model is loaded and frames can actually be analysed.
    @Published private(set) var isModelReady = false

    private var setupTask: Task<Void, Never>?
    private var inferenceTask: Task<Void, Never>?
    private let modelTask: Task<PoseLandmarkerService, Error>
    private let orientationLoader: @Sendable (AVAsset) async -> UIImage.Orientation
    private var sessionID = UUID()

    init(
        orientationLoader: @escaping @Sendable (AVAsset) async -> UIImage.Orientation = {
            await VideoPoseViewModel.orientation(for: $0)
        }
    ) {
        self.orientationLoader = orientationLoader
        // One warmup per view model. It may finish offscreen, but never publishes UI or starts playback.
        modelTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let service = try PoseLandmarkerService()
            try Task.checkCancellation()
            return service
        }
    }

    deinit {
        setupTask?.cancel()
        inferenceTask?.cancel()
        modelTask.cancel()
        displayLink?.invalidate()
        if let playerObserverToken { NotificationCenter.default.removeObserver(playerObserverToken) }
    }

    func load(url: URL) {
        stop()
        let session = sessionID
        let loader = orientationLoader
        let model = modelTask
        status = L("Preparing motion analysis...")
        setupTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let orientation = await loader(asset)
            guard !Task.isCancelled else { return }
            do {
                let service = try await model.value
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.service = service
                self.isModelReady = true
                self.orientation = orientation
                self.setupPlayer(asset: asset, session: session)
                self.setupTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.sessionID == session else { return }
                self.status = String(format: L("Failed to load model: %@"), error.localizedDescription)
                self.setupTask = nil
            }
        }
    }

    private func setupPlayer(asset: AVAsset, session: UUID) {
        let item = AVPlayerItem(asset: asset)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        videoOutput = output
        player.replaceCurrentItem(with: item)

        playerObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.isRunning, self.sessionID == session,
                      self.player.currentItem === item else { return }
                let finished = await self.player.seek(to: .zero)
                // Removing the observer cannot recall a seek already in flight.
                guard finished, self.isRunning, self.sessionID == session,
                      self.player.currentItem === item else { return }
                self.player.play()
            }
        }

        isRunning = true
        startDisplayLink()
        player.play()
        status = L("Detecting… (BlazePose Heavy)")
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = DisplayLinkProxy.create(target: self) { [weak self] _ in
            self?.onFrame()
        }
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func onFrame() {
        guard isRunning, !isProcessing, let output = videoOutput, let service else { return }
        let time = player.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time,
                                                       itemTimeForDisplay: nil) else { return }

        isProcessing = true
        monotonicMs += 33
        let timestamp = monotonicMs
        let frameOrientation = orientation
        let session = sessionID

        inferenceTask = Task.detached(priority: .userInitiated) { [weak self, service] in
            let result = Task.isCancelled ? nil : service.detect(
                pixelBuffer: pixelBuffer,
                orientation: frameOrientation,
                timestampMs: timestamp
            )
            let cancelled = Task.isCancelled
            await self?.finishInference(result, cancelled: cancelled, session: session)
        }
    }

    private func finishInference(_ result: PoseFrameResult?, cancelled: Bool, session: UUID) {
        // Keep the lock until native inference really finishes, even after stop/load.
        // Starting a second detect on the same MediaPipe instance would race its video state.
        isProcessing = false
        inferenceTask = nil
        guard !cancelled, isRunning, sessionID == session, let result else { return }
        landmarks = result.normalized.first ?? []
        if let world = result.world.first { onWorld?(world) }
    }

    func stop() {
        sessionID = UUID()
        setupTask?.cancel()
        setupTask = nil
        inferenceTask?.cancel()
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        displayLink?.invalidate()
        displayLink = nil
        if let token = playerObserverToken {
            NotificationCenter.default.removeObserver(token)
            playerObserverToken = nil
        }
        videoOutput = nil
        player.replaceCurrentItem(with: nil)
        landmarks = []
        isRunning = false
        status = L("Select a video")
    }

    /// Infers the image orientation fed to MediaPipe from the video track's preferredTransform.
    private nonisolated static func orientation(for asset: AVAsset) async -> UIImage.Orientation {
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
