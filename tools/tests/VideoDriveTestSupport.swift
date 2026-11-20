import Foundation
import CoreVideo
import UIKit
import simd

nonisolated enum SketchfabClient {
    static let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-models")
}

// Inference is controlled, while the production view model uses real AVPlayer playback, video outputs,
// display links, file transfers and AVFoundation validation.
nonisolated final class PoseLandmarkerService: @unchecked Sendable {
    static let control = DetectionControl()
    init() throws {}

    func detect(pixelBuffer: CVPixelBuffer, orientation: UIImage.Orientation, timestampMs: Int) -> PoseFrameResult? {
        Self.control.detect(timestamp: timestampMs)
    }
}

nonisolated final class DetectionControl: @unchecked Sendable {
    private let condition = NSCondition()
    private var shouldBlockFirst = false
    private var released = false
    private var started: ((Int) -> Void)?
    private var calls = 0
    private var active = 0
    private var maximumActive = 0
    private var clock: [Int] = []

    func reset(blockFirst: Bool = false, onStarted: ((Int) -> Void)? = nil) {
        condition.lock()
        shouldBlockFirst = blockFirst
        released = false
        started = onStarted
        calls = 0
        active = 0
        maximumActive = 0
        clock = []
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    var snapshot: (calls: Int, maximumActive: Int, timestamps: [Int]) {
        condition.lock()
        defer { condition.unlock() }
        return (calls, maximumActive, clock)
    }

    func detect(timestamp: Int) -> PoseFrameResult {
        condition.lock()
        calls += 1
        let number = calls
        active += 1
        maximumActive = max(maximumActive, active)
        clock.append(timestamp)
        let callback = started
        condition.unlock()
        callback?(number)
        condition.lock()
        while shouldBlockFirst && number == 1 && !released { condition.wait() }
        active -= 1
        condition.unlock()
        return PoseFrameResult(
            normalized: [[NormalizedLandmarkLite(x: CGFloat(number), y: 0.5, visibility: 1)]],
            world: [[simd_float3(Float(number), 0, 0)]]
        )
    }
}

actor VideoTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
