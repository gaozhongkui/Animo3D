//
//  VideoAudioMixer.swift
//  Animo3D
//
//  导出作品：合成 视频 + (可选)背景音乐 + (非会员)右下角 "Animo3D" 水印。
//

import Foundation
import AVFoundation
import UIKit

enum VideoAudioMixer {
    /// 导出最终作品。audio 为 nil 则不加音乐；watermark=true 时右下角打 "Animo3D"。
    static func export(video videoURL: URL, audio audioURL: URL?, watermark: Bool) async -> URL? {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)

        do {
            guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first else { return nil }
            let vDur = try await videoAsset.load(.duration)
            guard vDur.seconds > 0 else { return nil }
            let naturalSize = try await vSrc.load(.naturalSize)
            let transform = try await vSrc.load(.preferredTransform)

            guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
            vTrack.preferredTransform = transform

            // 背景音乐（循环铺满）
            if let audioURL {
                let audioAsset = AVURLAsset(url: audioURL)
                if let aSrc = try await audioAsset.loadTracks(withMediaType: .audio).first {
                    let aDur = try await audioAsset.load(.duration)
                    if aDur.seconds > 0,
                       let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        var cursor = CMTime.zero
                        while cursor < vDur {
                            let chunk = CMTimeMinimum(aDur, vDur - cursor)
                            try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: aSrc, at: cursor)
                            cursor = cursor + chunk
                        }
                    }
                }
            }

            let out = FileManager.default.temporaryDirectory.appendingPathComponent("out_\(UUID().uuidString).mp4")
            guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return nil }
            export.outputURL = out
            export.outputFileType = .mp4

            // 水印：用 CoreAnimation 图层在右下角叠加产品名
            if watermark {
                let renderSize = naturalSize.applying(transform)
                let size = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))
                export.videoComposition = watermarkComposition(track: vTrack, size: size, duration: vDur)
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }
            if export.status == .completed { return out }
            print("[Export] 失败: \(export.error?.localizedDescription ?? "unknown")")
            return nil
        } catch {
            print("[Export] 异常: \(error.localizedDescription)")
            return nil
        }
    }

    private static func watermarkComposition(track: AVCompositionTrack, size: CGSize, duration: CMTime) -> AVMutableVideoComposition {
        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)

        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstr.setTransform(track.preferredTransform, at: .zero)
        instr.layerInstructions = [layerInstr]
        vc.instructions = [instr]

        // 图层树：视频层 + 水印文字层
        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer(); videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let fontSize = max(18, size.height * 0.028)
        let text = CATextLayer()
        text.string = "Animo3D"
        text.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        text.fontSize = fontSize
        text.foregroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        text.shadowColor = UIColor.black.cgColor
        text.shadowOpacity = 0.5; text.shadowRadius = 3; text.shadowOffset = .zero
        text.alignmentMode = .right
        text.contentsScale = 2
        let margin = size.height * 0.02
        let tw = fontSize * 5.2, th = fontSize * 1.4
        text.frame = CGRect(x: size.width - tw - margin, y: margin, width: tw, height: th) // 右下角(视频坐标系原点在左下)
        parent.addSublayer(text)

        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        return vc
    }
}
