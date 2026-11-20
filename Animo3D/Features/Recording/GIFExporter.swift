import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Only a temporary export is owned here; releasing it never removes the source recording.
nonisolated final class ExportedGIF: Sendable {
    let url: URL
    private let ownedDirectory: URL?
    init(temporaryURL: URL, ownedDirectory: URL? = nil) {
        url = temporaryURL
        self.ownedDirectory = ownedDirectory
    }
    deinit { try? FileManager.default.removeItem(at: ownedDirectory ?? url) }
}

nonisolated enum GIFExportError: Error {
    case invalidVideo
    case frameFailed
    case writeFailed
}

nonisolated enum GIFExporter {
    /// Exports up to the first six seconds. Progress is delivered on the export executor.
    static func convertToGIF(
        videoURL: URL,
        maxDimension: CGFloat = 480,
        fps: Double = 12,
        durationLimit: Double = 6,
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("GIFExports"),
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> ExportedGIF {
        try Task.checkCancellation()
        guard fps.isFinite, fps > 0, durationLimit.isFinite, durationLimit > 0,
              maxDimension.isFinite, maxDimension > 0 else { throw GIFExportError.invalidVideo }
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration).seconds
        guard !tracks.isEmpty, duration.isFinite, duration > 0 else { throw GIFExportError.invalidVideo }
        let actualDuration = min(duration, durationLimit)
        let requestedFrames = (actualDuration * fps).rounded(.up)
        guard requestedFrames < Double(Int.max) else { throw GIFExportError.invalidVideo }
        let frameCount = max(1, Int(requestedFrames))
        let frameInterval = actualDuration / Double(frameCount)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // ImageIO may create auxiliary files; each job owns an entire private directory.
        let jobDirectory = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        let file = ExportedGIF(
            temporaryURL: jobDirectory.appendingPathComponent("animation.gif"),
            ownedDirectory: jobDirectory
        )
        var completed = false
        defer {
            // A failed Task can retain its async frame; clean failed exports before throwing.
            if !completed { try? FileManager.default.removeItem(at: jobDirectory) }
        }
        guard let destination = CGImageDestinationCreateWithURL(
            file.url as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { throw GIFExportError.writeFailed }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frameInterval]
        ] as CFDictionary
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let result = try await withTaskCancellationHandler {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let time = CMTime(seconds: Double(index) * frameInterval, preferredTimescale: 600)
                let image: CGImage
                do {
                    image = try await generator.image(at: time).image
                } catch {
                    try Task.checkCancellation()
                    throw GIFExportError.frameFailed
                }
                try Task.checkCancellation()
                CGImageDestinationAddImage(destination, image, frameProperties)
                onProgress?(Float(index + 1) / Float(frameCount))
            }
            try Task.checkCancellation()
            guard CGImageDestinationFinalize(destination) else { throw GIFExportError.writeFailed }
            try Task.checkCancellation()
            return file
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
        completed = true
        return result
    }
}
