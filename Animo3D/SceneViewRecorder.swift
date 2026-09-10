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
import ARKit
import AVFoundation
import Combine
import UIKit

/// Holds the SCNView currently used for recording (written by CharacterSceneView / ARCharacterView on creation).
final class SceneHolder: ObservableObject {
    weak var scnView: SCNView?
}

final class SceneViewRecorder: ObservableObject {

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
    /// Offscreen renderer used for the plain stage. Reused: building one per frame would cost more
    /// than the render it does.
    private var offscreen: SCNRenderer?
    /// The watermark, rasterised once, plus where it goes. Laying out attributed text and blurring
    /// its shadow is not something to do thirty times a second for a string that never changes.
    private var watermarkImage: CGImage?
    private var watermarkOrigin = CGPoint.zero
    private var outURL: URL?
    /// Text burned into every frame, or nil for Pro users.
    private var watermark: String?
    /// Everything after the render happens here. Only the SceneKit render has to be on the main
    /// thread (the scene graph is mutated there); the CoreGraphics draw into the pixel buffer and
    /// the append do not, and on a slower device they are the difference between fitting in a tick
    /// and not. Serial, so frames stay in order.
    private let encodeQueue = DispatchQueue(label: "SceneViewRecorder.encode", qos: .userInitiated)
    /// Frames handed to `encodeQueue` and not yet written. Bounded: if the encoder falls behind,
    /// dropping the newest frame is correct now that presentation times come from the clock.
    private var pending = 0
    private let pendingLock = NSLock()
    /// The view's own frame rate before recording lowered it, or nil if it was left alone.
    private var previousViewFPS: Int?

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
        // The cap is per tier: an A11 with 3GB cannot render this scene twice a frame at 1920 and
        // still keep the stage moving, which is what "recording is a bit laggy" on iOS 16.7 is.
        let maxLongSide = DeviceTier.captureLongSide
        let screenScale = view.window?.screen.scale ?? UIScreen.main.scale
        let longSide = max(view.bounds.width, view.bounds.height) * screenScale
        let scale = longSide > maxLongSide ? screenScale * (maxLongSide / longSide) : screenScale
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
        let fps = DeviceTier.captureFPS
        let bitrate = min(24_000_000,
                          max(4_000_000, Int(Double(w * h * fps) * DeviceTier.captureBitsPerPixel)))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // One keyframe a second: enough for scrubbing without spending the budget on them.
                AVVideoMaxKeyFrameIntervalKey: fps,
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
        prepareWatermark()

        // An offscreen renderer that draws straight at the capture size.
        //
        // `SCNView.snapshot()` re-renders the whole scene at the view's own native resolution, on
        // the main thread, and hands back a UIImage that then has to be resampled down by
        // CoreGraphics. So recording meant rendering every frame twice - the second time larger
        // than the file needs - and then paying for a CPU resize on top. Rendering once, at exactly
        // the size being encoded, with antialiasing off, removes both. It is the same
        // `SCNRenderer` pattern the thumbnail renderer already uses.
        //
        // Not for AR: `ARSCNView` composites the camera feed itself, and a plain SCNRenderer over
        // the same scene would give a character floating on nothing. That path keeps `snapshot()`.
        if !(view is ARSCNView), let device = view.device {
            let r = SCNRenderer(device: device, options: nil)
            r.scene = view.scene
            offscreen = r
        } else {
            offscreen = nil
        }

        // On a struggling device, make the two render passes share a tick.
        //
        // The view draws on its own display link and this one draws the capture; at 30 and 24 they
        // beat against each other, so some ticks carry both renders and some carry one, which is
        // felt as uneven motion rather than as a uniformly lower frame rate. Matching them while
        // recording costs the live preview a few frames a second and gives the file - the thing
        // that is kept - an even cadence. Restored in stop().
        if DeviceTier.isLowEnd {
            previousViewFPS = view.preferredFramesPerSecond
            view.preferredFramesPerSecond = fps
        }

        let l = CADisplayLink(target: self, selector: #selector(capture(_:)))
        l.preferredFramesPerSecond = fps
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

        // Two frames in flight is enough to keep the encoder busy without letting a backlog build.
        pendingLock.lock()
        let backlog = pending
        if backlog < 2 { pending += 1 }
        pendingLock.unlock()
        guard backlog < 2 else { return }

        let image: UIImage
        if let r = offscreen {
            r.pointOfView = view.pointOfView      // the stage camera moves during the performance
            image = r.snapshot(atTime: link.timestamp, with: size, antialiasingMode: .none)
        } else {
            image = view.snapshot()
        }
        lastPTS = pts

        let frameSize = size
        encodeQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
            }
            guard let pb = self.pixelBuffer(from: image, size: frameSize,
                                            pool: adaptor.pixelBufferPool) else { return }
            adaptor.append(pb, withPresentationTime: pts)
        }
    }

    /// Rasterise the watermark once, at the size it will be drawn.
    private func prepareWatermark() {
        watermarkImage = nil
        guard let text = watermark, size.width > 1 else { return }

        // All calculations here are in PIXELS to match the video buffer.
        let fontSize = max(18, size.height * 0.028)
        let pad: CGFloat = 10 // Increased padding for better shadow clearance

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

        let textSize = (text as NSString).size(withAttributes: attrs)
        let boxSize = CGSize(width: ceil(textSize.width) + pad * 2,
                             height: ceil(textSize.height) + pad * 2)

        // Force scale to 1.0 so the points in the renderer map 1:1 to video pixels.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: boxSize, format: format)

        let img = renderer.image { _ in
            (text as NSString).draw(at: CGPoint(x: pad, y: pad), withAttributes: attrs)
        }
        watermarkImage = img.cgImage

        let margin = size.height * 0.02
        // Position relative to the bottom-right, all in pixels.
        watermarkOrigin = CGPoint(x: size.width - boxSize.width - margin + pad,
                                  y: size.height - boxSize.height - margin + pad)
    }

    func stop(completion: @escaping (URL?) -> Void) {
        guard isRecording else { completion(nil); return }
        isRecording = false
        link?.invalidate(); link = nil
        offscreen = nil
        if let fps = previousViewFPS { view?.preferredFramesPerSecond = fps; previousViewFPS = nil }
        let url = outURL
        // Through the same serial queue the appends go through, so every frame already handed over
        // is written before the input is closed. Calling markAsFinished() straight from here would
        // race the last frame or two and truncate the clip.
        encodeQueue.async { [weak self] in
            guard let self else { return }
            self.input?.markAsFinished()
            self.writer?.finishWriting {
                let ok = self.writer?.status == .completed
                DispatchQueue.main.async { completion(ok ? url : nil) }
            }
        }
    }

    private func pixelBuffer(from image: UIImage, size: CGSize,
                             pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        // The adaptor's own pool, when it has one. Allocating a fresh buffer per frame means the
        // system zeroes several megabytes thirty times a second and then throws it away; the pool
        // hands back the one the encoder has already finished with.
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        }
        if pb == nil {
            let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                         kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
            CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32ARGB, attrs, &pb)
        }
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
        if let mark = watermarkImage {
            let w = CGFloat(mark.width), h = CGFloat(mark.height)
            let pad: CGFloat = 10
            // The context is bottom-left origin. Draw the watermark image (the whole box)
            // so that its visible text ends up at the correct margin.
            ctx.draw(mark, in: CGRect(x: watermarkOrigin.x - pad,
                                      y: size.height - watermarkOrigin.y - h + pad,
                                      width: w, height: h))
        }
        return buffer
    }

    /// Bottom-right product mark.
    ///
    /// A CGBitmapContext has its origin at the bottom left while UIKit text drawing assumes the
    /// opposite, so the context is flipped for the text alone - the frame itself is already drawn
    /// the right way up by the CGImage blit above.
}
