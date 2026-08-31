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
    @Published var isRecording = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var link: CADisplayLink?
    private weak var view: SCNView?
    private var size = CGSize.zero
    private var frameIndex: Int64 = 0
    private var outURL: URL?
    /// Text burned into every frame, or nil for Pro users.
    private var watermark: String?

    func start(view: SCNView, watermark: String? = nil) {
        guard !isRecording else { return }
        self.view = view
        self.watermark = watermark
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        func even(_ v: CGFloat) -> Int { let n = Int(v * scale); return n - (n % 2) }
        let w = max(2, even(view.bounds.width)), h = max(2, even(view.bounds.height))
        size = CGSize(width: w, height: h)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cap_\(UUID().uuidString).mp4")
        outURL = url
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h
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
        frameIndex = 0

        let l = CADisplayLink(target: self, selector: #selector(capture))
        l.preferredFramesPerSecond = 30
        l.add(to: .main, forMode: .common)
        link = l
        isRecording = true
    }

    @objc private func capture() {
        guard let view, let input, let adaptor, input.isReadyForMoreMediaData else { return }
        let image = view.snapshot()
        guard let pb = pixelBuffer(from: image, size: size) else { return }
        let time = CMTime(value: frameIndex, timescale: 30)
        adaptor.append(pb, withPresentationTime: time)
        frameIndex += 1
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
