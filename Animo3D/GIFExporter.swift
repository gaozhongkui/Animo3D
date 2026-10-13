//
//  GIFExporter.swift
//  Animo3D
//
//  Generates animated GIF files from recorded video clips.
//

import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum GIFExporter {
    /// Generates an animated GIF from a video file URL.
    /// - Parameters:
    ///   - videoURL: Source video URL.
    ///   - maxDimension: Maximum width/height for GIF frames (default: 480).
    ///   - fps: Target frame rate for GIF (default: 12 fps).
    ///   - durationLimit: Maximum video duration to convert in seconds (default: 6s).
    ///   - onProgress: Real-time progress callback from 0.0 to 1.0.
    /// - Returns: Local file URL to the generated animated GIF, or nil on failure.
    static func convertToGIF(
        videoURL: URL,
        maxDimension: CGFloat = 480,
        fps: Double = 12.0,
        durationLimit: Double = 6.0,
        onProgress: ((Float) -> Void)? = nil
    ) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        guard let dur = try? await asset.load(.duration), dur.seconds > 0 else { return nil }

        let actualDuration = min(dur.seconds, durationLimit)
        let frameCount = Int(actualDuration * fps)
        guard frameCount > 0 else { return nil }

        let frameInterval = actualDuration / Double(frameCount)
        var times: [CMTime] = []
        for i in 0..<frameCount {
            let timeSeconds = Double(i) * frameInterval
            times.append(CMTime(seconds: timeSeconds, preferredTimescale: 600))
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let gifURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gif_\(UUID().uuidString).gif")

        guard let destination = CGImageDestinationCreateWithURL(
            gifURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else { return nil }

        let fileProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0 // Loop infinitely
            ]
        ]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: frameInterval
            ]
        ]

        var processedCount = 0

        for time in times {
            do {
                let (cgImage, _) = try await generator.image(at: time)
                CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
                processedCount += 1
                let progress = Float(processedCount) / Float(frameCount)
                await MainActor.run { onProgress?(progress) }
            } catch {
                print("[GIFExporter] Error generating frame at \(time.seconds)s: \(error.localizedDescription)")
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return gifURL
    }
}
