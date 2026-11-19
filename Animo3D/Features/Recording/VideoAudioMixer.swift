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
    /// Require the selected audio to be usable; never report a silent export as music success.
    static func export(
        video videoURL: URL,
        audio audioURL: URL?,
        onProgress: ((Float) -> Void)? = nil
    ) async throws -> URL {
        let comp = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)

        var outputURL: URL?
        do {
            guard let vSrc = try await videoAsset.loadTracks(withMediaType: .video).first else {
                throw RecordingError.noFrames
            }
            let vDur = try await videoAsset.load(.duration)
            guard vDur.seconds.isFinite, vDur.seconds > 0 else { throw RecordingError.noFrames }
            let transform = try await vSrc.load(.preferredTransform)

            guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
                NSLog("[Export] could not create the video composition track")
                throw RecordingError.encodingFailed
            }
            try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: vSrc, at: .zero)
            vTrack.preferredTransform = transform

            if let audioURL {
                let audioAsset = AVURLAsset(url: audioURL)
                guard let source = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let audioDuration = try await audioAsset.load(.duration)
                guard audioDuration.seconds.isFinite, audioDuration.seconds > 0,
                      let track = comp.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                      ) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var cursor = CMTime.zero
                while cursor < vDur {
                    try Task.checkCancellation()
                    let chunk = CMTimeMinimum(audioDuration, vDur - cursor)
                    try track.insertTimeRange(
                        CMTimeRange(start: .zero, duration: chunk),
                        of: source,
                        at: cursor
                    )
                    cursor = cursor + chunk
                }
            }

            let out = FileManager.default.temporaryDirectory.appendingPathComponent("out_\(UUID().uuidString).mp4")
            outputURL = out
            guard let export = AVAssetExportSession(
                asset: comp,
                presetName: AVAssetExportPresetHighestQuality
            ) else {
                NSLog("[Export] export session unavailable for video duration %.3f", vDur.seconds)
                throw RecordingError.encodingFailed
            }
            export.outputURL = out
            export.outputFileType = .mp4

            // 实时导出进度轮询任务 (每 50ms 回调一次进度)
            let progressTask = Task {
                while !Task.isCancelled {
                    let currentProgress = export.progress
                    onProgress?(currentProgress)
                    if export.status == .completed || export.status == .failed || export.status == .cancelled {
                        break
                    }
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {
                        return
                    }
                }
            }

            defer { progressTask.cancel() }

            // 使用标准 Swift 现代并发方案，配合一个带锁的原子隔离闭包隔离处理，彻底杜绝底层多线程并发状态导致的 Continuation 多次 Resume Crash 隐患。
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                let lock = NSLock()
                var resumed = false
                export.exportAsynchronously {
                    lock.lock()
                    if !resumed {
                        resumed = true
                        lock.unlock()
                        cont.resume()
                    } else {
                        lock.unlock()
                    }
                }
            }

            if export.status == .completed {
                onProgress?(1.0)
                return out
            }
            NSLog(
                "[Export] did not complete, status %ld: %@",
                export.status.rawValue,
                export.error?.localizedDescription ?? "No underlying export error"
            )
            throw export.error ?? RecordingError.encodingFailed
        } catch {
            if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
            throw error
        }
    }

}
