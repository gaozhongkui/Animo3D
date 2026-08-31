//
//  VideoAudioMixer.swift
//  Animo3D
//
//  Export work: mix the recorded video with the chosen background music.
//
//  The watermark used to be added here through AVVideoCompositionCoreAnimationTool. That drives
//  CARenderer to allocate an IOSurface per frame, which in the Simulator goes over XPC shared
//  memory, fails, and takes the process down with an "API Misuse" trap. It is now burned into the
//  frames by SceneViewRecorder while recording, so this file only ever mixes audio - and when there
//  is no music to mix, the caller does not need to export at all.
//

import Foundation
import AVFoundation
import UIKit

enum VideoAudioMixer {
    /// Mix background music into a recorded clip. Returns nil if anything fails, so the caller can
    /// fall back to the original recording.
    static func export(video videoURL: URL, audio audioURL: URL?) async -> URL? {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)

        do {
            guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first else { return nil }
            let vDur = try await videoAsset.load(.duration)
            guard vDur.seconds > 0 else { return nil }
            let transform = try await vSrc.load(.preferredTransform)

            guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
            vTrack.preferredTransform = transform

            // Background music (loop to fill)
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

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                var resumed = false
                export.exportAsynchronously {
                    if !resumed {
                        resumed = true
                        cont.resume()
                    }
                }
            }
            if export.status == .completed { return out }
            print("[Export] failed: \(export.error?.localizedDescription ?? "unknown")")
            return nil
        } catch {
            print("[Export] error: \(error.localizedDescription)")
            return nil
        }
    }

}
