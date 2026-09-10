//
//  SceneViewRecorder.swift
//  Animo3D
//
//  Records only the SCNView holding the character (without the UI pickers). It works for both screen and AR, and can be verified in the Simulator.
//  Per-frame snapshot() -> written to mp4 by AVAssetWriter.
//
//  The free-tier watermark is burned in here, frame by frame, rather than layered on at export.
//  Export used to attach an AVVideoCompositionCoreAnimationTool, which drives CARenderer to build
//  an IOSurface per frame; in the Simulator that path goes through XPC shared memory, fails, and
//  kills the process ("API Misuse" inside _xpc_shmem_create_with_prot). Drawing the text straight
//  into the pixel buffer needs no compositor at all, and it also means a watermark-only export is
//  no longer an export - the file is already correct when recording stops.
//

import SwiftUI
import SceneKit
import AVFoundation
import Combine
import UIKit

/// Holds the SCNView currently used for recording (written by CharacterSceneView / ARCharacterView on creation).
final class SceneHolder: ObservableObject {
    weak var scnView: SCNView?
}

final class SceneViewRecorder: ObservableObject {
    /// Longest edge of a recorded frame, in pixels.
    static let maxLongSide: CGFloat = 1920

    @Published var isRecording = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var link: CADisplayLink?
    private weak var view: SCNView?
    private var size = CGSize.zero
    /// When the first frame was captured, and the last presentation time written. Frames are
    /// timestamped from the clock, not counted, so the two have to be remembered across ticks.
    private var startTimestamp: CFTimeInterval = 0
    private var lastPTS = CMTime.zero
    private var outURL: URL?
    /// Text burned into every frame, or nil for Pro users.
    private var watermark: String?

    func start(view: SCNView, watermark: String? = nil) {
        guard !isRecording else { return }
        self.view = view
        self.watermark = watermark
        // Capture scale is capped, not taken straight from the screen.
        //
        // At native retina an iPhone 17 Pro frame is 1206x2622 and an iPad is larger still, and
        // every one of those frames costs an SCNView.snapshot() plus a full CGContext draw. That
        // does not fit in a 30Hz tick, so ticks get skipped - which is what made the finished video
        // play fast, back when frames were timestamped by index. Capping the long side at 1920
        // roughly halves the per-frame work, keeps the aspect exactly, and is a more ordinary size
        // to hand to a share sheet than a 2622-pixel-tall file.
        let screenScale = view.window?.screen.scale ?? UIScreen.main.scale
        let longSide = max(view.bounds.width, view.bounds.height) * screenScale
        let scale = longSide > Self.maxLongSide
            ? screenScale * (Self.maxLongSide / longSide) : screenScale
        func even(_ v: CGFloat) -> Int { let n = Int(v * scale); return n - (n % 2) }
        let w = max(2, even(view.bounds.width)), h = max(2, even(view.bounds.height))
        size = CGSize(width: w, height: h)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap_\(UUID().uuidString).mp4")
        outURL = url
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        // An explicit bitrate. Without AVVideoCompressionPropertiesKey the encoder picks its own
        // default for the dimensions, and for a frame this size that default is low enough to show
        // as mush on the character's face and banding across the stage floor - the "quality is bad"
        // half of the report. 0.15 bits per pixel per frame is the usual rule of thumb for h264;
        // the clamp keeps a small frame from being starved and a huge one from being absurd.
        let bitrate = min(24_000_000, max(6_000_000, Int(Double(w * h * 30) * 0.15)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // One keyframe a second: enough for scrubbing without spending the budget on them.
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h
            ])
        guard writer.canAdd(input) else { return }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.writer = writer; self.input = input; self.adaptor = adaptor
        startTimestamp = 0
        lastPTS = .zero

        let l = CADisplayLink(target: self, selector: #selector(capture(_:)))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
        isRecording = true
    }

    @objc private func capture(_ link: CADisplayLink) {
        guard let view, let input, let adaptor, input.isReadyForMoreMediaData else { return }

        // Timestamp from the clock, never from a frame count.
        //
        // This used to write `CMTime(value: frameIndex, timescale: 30)`, which says "every frame I
        // appended is exactly 1/30s after the last one". But frames are dropped all the time - the
        // guard above declines whenever the encoder is busy, and a snapshot that overruns its tick
        // makes the display link skip the next one. Every dropped frame therefore removed 1/30s
        // from the finished video while real time went on, so a 20s dance came out as maybe 14s of
        // footage and played visibly fast. That is the whole of the "感觉有点加速" report; nothing
        // was actually being played faster, the file was simply short.
        //
        // Elapsed time also keeps the audio mix honest: VideoAudioMixer lays the track against the
        // video's duration, so a video that ran short desynchronised the music as well.
        if startTimestamp == 0 { startTimestamp = link.timestamp }
        var pts = CMTime(seconds: max(0, link.timestamp - startTimestamp), preferredTimescale: 600)
        // Presentation times have to strictly increase; two ticks inside one 1/600s would not.
        if pts <= lastPTS { pts = lastPTS + CMTime(value: 1, timescale: 600) }

        let image = view.snapshot()
        guard let pb = pixelBuffer(from: image, size: size) else { return }
        adaptor.append(pb, withPresentationTime: pts)
        lastPTS = pts
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false
        link?.invalidate(); link = nil
        input?.markAsFinished()
        let url = outURL
        writer?.finishWriting { [weak self] in
            let ok = self?.writer?.status == .completed
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
    }

    private func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        if let cg = image.cgImage {
            ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        }
        if let watermark { draw(watermark, in: ctx, size: size) }
        return buffer
    }

    /// Bottom-right product mark.
    ///
    /// A CGBitmapContext has its origin at the bottom left while UIKit text drawing assumes the
    /// opposite, so the context is flipped for the text alone - the frame itself is already drawn
    /// the right way up by the CGImage blit above.
    private func draw(_ text: String, in ctx: CGContext, size: CGSize) {
        let fontSize = max(18, size.height * 0.028)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            .shadow: {
                let sh = NSShadow()
                sh.shadowColor = UIColor.black.withAlphaComponent(0.5)
                sh.shadowBlurRadius = 3
                return sh
            }()
        ]
        let bounds = (text as NSString).size(withAttributes: attrs)
        let margin = size.height * 0.02

        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        (text as NSString).draw(at: CGPoint(x: size.width - bounds.width - margin,
                                            y: size.height - bounds.height - margin),
                                withAttributes: attrs)
        UIGraphicsPopContext()
        ctx.restoreGState()
    }
}
