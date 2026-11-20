import Foundation

/// Measures active playback time. The first frame after a pause keeps the last displayed pose.
nonisolated struct AnimationPlaybackClock {
    private var previousTimestamp: TimeInterval?
    private(set) var elapsed: TimeInterval = 0

    mutating func advance(to timestamp: TimeInterval) -> TimeInterval {
        if let previousTimestamp {
            elapsed += max(0, timestamp - previousTimestamp)
        }
        previousTimestamp = timestamp
        return elapsed
    }

    mutating func suspend() {
        previousTimestamp = nil
    }

    mutating func reset() {
        elapsed = 0
        previousTimestamp = nil
    }
}
