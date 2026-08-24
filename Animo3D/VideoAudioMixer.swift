//
//  VideoAudioMixer.swift
//  Animo3D
//
//  把录制的无声视频与选中的背景音乐合成为一个带声音的 mp4（音乐循环铺满视频时长）。
//  录屏本身只有画面，分享前用它加上音乐。
//

import Foundation
import AVFoundation

enum VideoAudioMixer {
    /// 合成 video(无声) + audio(循环) → 新 mp4。失败返回 nil。
    static func mix(video videoURL: URL, audio audioURL: URL) async -> URL? {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        do {
            guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first else { return nil }
            let vDur = try await videoAsset.load(.duration)
            guard vDur.seconds > 0 else { return nil }

            guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
            vTrack.preferredTransform = try await vSrc.load(.preferredTransform)

            // 音乐轨：循环铺满视频时长
            if let aSrc = try await audioAsset.loadTracks(withMediaType: .audio).first {
                let aDur = try await audioAsset.load(.duration)
                if aDur.seconds > 0,
                   let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid) {
                    var cursor = CMTime.zero
                    while cursor < vDur {
                        let remaining = vDur - cursor
                        let chunk = CMTimeMinimum(aDur, remaining)
                        try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: aSrc, at: cursor)
                        cursor = cursor + chunk
                    }
                }
            }

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("mixed_\(UUID().uuidString).mp4")
            guard let export = AVAssetExportSession(asset: comp,
                                                    presetName: AVAssetExportPresetHighestQuality) else { return nil }
            export.outputURL = out
            export.outputFileType = .mp4

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }

            if export.status == .completed { return out }
            print("[Mix] 导出失败: \(export.error?.localizedDescription ?? "unknown")")
            return nil
        } catch {
            print("[Mix] 合成失败: \(error.localizedDescription)")
            return nil
        }
    }
}
