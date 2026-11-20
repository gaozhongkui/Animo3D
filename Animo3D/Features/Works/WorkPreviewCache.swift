import AVFoundation
import UIKit

nonisolated struct WorkPreview: @unchecked Sendable {
    let thumbnail: UIImage?
    let duration: TimeInterval
    let date: Date?

    var durationText: String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "--:--" }
        let seconds = Int(duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var dateText: String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        return formatter.string(from: date)
    }
}

/// Bounded background decoding, shared by gallery cells and the system share preview.
actor WorkPreviewCache {
    static let shared = WorkPreviewCache()
    typealias Decoder = @Sendable (URL) async throws -> WorkPreview

    private struct Stamp: Equatable, Sendable {
        let size: Int?
        let modified: Date?
        init(_ url: URL) throws {
            // URL resource values can themselves be cached after an in-place file replacement.
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (values[.size] as? NSNumber)?.intValue
            modified = values[.modificationDate] as? Date
        }
    }

    private final class Entry {
        let stamp: Stamp
        let preview: WorkPreview
        init(stamp: Stamp, preview: WorkPreview) {
            self.stamp = stamp
            self.preview = preview
        }
    }

    private struct Pending: Sendable {
        let id: UUID
        let stamp: Stamp
        let task: Task<WorkPreview, Error>
        var consumers: Set<UUID>
    }

    private let cache = NSCache<NSURL, Entry>()
    private let decode: Decoder
    private let concurrencyLimit: Int
    private var inFlight: [URL: Pending] = [:]
    private var activeCount = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(concurrencyLimit: Int = 2, decode: @escaping Decoder = WorkPreviewCache.decodeFile) {
        self.concurrencyLimit = max(1, concurrencyLimit)
        self.decode = decode
        cache.countLimit = 60
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func preview(for url: URL) async throws -> WorkPreview {
        try Task.checkCancellation()
        let stamp = try Stamp(url)
        if let entry = cache.object(forKey: url as NSURL), entry.stamp == stamp { return entry.preview }
        let consumer = UUID()
        let pending: Pending
        if var existing = inFlight[url], existing.stamp == stamp {
            existing.consumers.insert(consumer)
            pending = existing
        } else {
            inFlight[url]?.task.cancel()
            let task = Task {
                try Task.checkCancellation()
                await acquireSlot()
                defer { releaseSlot() }
                try Task.checkCancellation()
                let preview = try await decode(url)
                try Task.checkCancellation()
                return preview
            }
            pending = Pending(id: UUID(), stamp: stamp, task: task, consumers: [consumer])
        }
        inFlight[url] = pending
        defer { releaseConsumer(consumer, url: url, request: pending.id) }
        let preview = try await withTaskCancellationHandler {
            try await pending.task.value
        } onCancel: {
            Task { await self.releaseConsumer(consumer, url: url, request: pending.id) }
        }
        try Task.checkCancellation()
        if inFlight[url]?.id == pending.id {
            inFlight[url] = nil
            if (try? Stamp(url)) == stamp {
                let image = preview.thumbnail?.cgImage
                let cost = (image?.bytesPerRow ?? 0) * (image?.height ?? 0)
                cache.setObject(Entry(stamp: stamp, preview: preview), forKey: url as NSURL, cost: cost)
            }
        }
        return preview
    }

    private func releaseConsumer(_ consumer: UUID, url: URL, request: UUID) {
        guard var pending = inFlight[url], pending.id == request,
              pending.consumers.remove(consumer) != nil else { return }
        if pending.consumers.isEmpty {
            inFlight[url] = nil
            pending.task.cancel()
        } else {
            inFlight[url] = pending
        }
    }

    func invalidate(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        inFlight.removeValue(forKey: url)?.task.cancel()
    }

    private func acquireSlot() async {
        if activeCount < concurrencyLimit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func releaseSlot() {
        if waiting.isEmpty {
            activeCount -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    private nonisolated static func decodeFile(_ url: URL) async throws -> WorkPreview {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let time = CMTime(seconds: min(0.5, duration / 2), preferredTimescale: 600)
        let image = try await withTaskCancellationHandler {
            try await generator.image(at: time).image
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        try Task.checkCancellation()
        let values = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = values?[.creationDate] as? Date
        return WorkPreview(thumbnail: UIImage(cgImage: image), duration: duration, date: date)
    }
}
