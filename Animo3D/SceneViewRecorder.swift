//
//  SceneViewRecorder.swift
//  Animo3D
//
//  只录制角色所在的 SCNView（不含 UI 选择器），屏幕/AR 都可用，模拟器也能验证。
//  逐帧 snapshot() → AVAssetWriter 写成 mp4。
//

import SwiftUI
import SceneKit
import AVFoundation
import Combine
import UIKit

/// 持有当前用于录制的 SCNView（由 CharacterSceneView / ARCharacterView 在创建时写入）。
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

    func start(view: SCNView) {
        guard !isRecording else { return }
        self.view = view
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
        return buffer
    }
}
