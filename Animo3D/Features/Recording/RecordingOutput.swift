import Foundation
import Combine
import AVFoundation
import Darwin

/// Saves the original before music export, and keeps enough context to retry the failed step.
@MainActor
final class RecordingOutput: ObservableObject {
    typealias AudioExporter = @MainActor (URL, URL, @escaping (Float) -> Void) async throws -> URL

    struct Issue: Identifiable {
        enum Stage { case recording, saving, music }
        let id = UUID()
        let stage: Stage
        let message: String

        var title: String {
            switch stage {
            case .recording: return "Recording failed"
            case .saving: return "Could not save video"
            case .music: return "Could not add music"
            }
        }
    }

    private enum Recovery {
        case saveOriginal(URL, audio: URL?)
        case mix(URL, audio: URL)
        case saveMixed(URL, original: URL, audio: URL)
    }

    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Float = 0
    @Published var issue: Issue?
    @Published var finished: FinishedWork?
    private(set) var savedOriginal: URL?
    private var recovery: Recovery?
    private var activeExportID: UUID?

    private let save: @MainActor (URL) throws -> URL
    private let removeOriginal: @MainActor (URL) -> Void
    private let exportAudio: AudioExporter

    init(
        save: @escaping @MainActor (URL) throws -> URL = { try WorksStore.shared.add(from: $0) },
        removeOriginal: @escaping @MainActor (URL) -> Void = { WorksStore.shared.delete($0) },
        exportAudio: @escaping AudioExporter = { video, audio, progress in
            try await VideoAudioMixer.export(video: video, audio: audio, onProgress: progress)
        }
    ) {
        self.save = save
        self.removeOriginal = removeOriginal
        self.exportAudio = exportAudio
    }

    var canRetry: Bool { recovery != nil }
    var canKeepOriginal: Bool { savedOriginal != nil }

    func reportRecordingError(_ error: Error) {
        recovery = nil
        savedOriginal = nil
        NSLog("[Recording] failed: %@", error.localizedDescription)
        issue = Issue(
            stage: .recording,
            message: Self.isStorageFull(error)
                ? NSLocalizedString("There is not enough free space to record. Free up storage and try again.", comment: "")
                : (error as? RecordingError)?.errorDescription
                    ?? NSLocalizedString("The recording could not be completed. Check available storage and try again.", comment: "")
        )
    }

    func process(_ result: Result<URL, Error>, audio: URL? = nil) async {
        guard !isProcessing else { return }
        issue = nil
        recovery = nil
        savedOriginal = nil
        switch result {
        case .failure(let error):
            reportRecordingError(error)
        case .success(let recording):
            await perform(.saveOriginal(recording, audio: audio))
        }
    }

    func retry() async {
        guard let recovery, !isProcessing else { return }
        issue = nil
        await perform(recovery)
    }

    func keepOriginal() {
        guard let savedOriginal else { return }
        if case .saveMixed(let mixed, _, _) = recovery, mixed != savedOriginal {
            try? FileManager.default.removeItem(at: mixed)
        }
        issue = nil
        recovery = nil
        complete(savedOriginal, hasMusic: false)
    }

    private func perform(_ recovery: Recovery) async {
        isProcessing = true
        progress = 0
        defer {
            isProcessing = false
            progress = 0
        }
        switch recovery {
        case .saveOriginal(let source, let audio):
            let original: URL
            do {
                original = try save(source)
                savedOriginal = original
            } catch {
                failSaving(error, recovery: recovery)
                return
            }
            if let audio {
                await mix(original, audio: audio)
            } else {
                complete(original, hasMusic: false)
            }
        case .mix(let original, let audio):
            await mix(original, audio: audio)
        case .saveMixed(let mixed, let original, let audio):
            if FileManager.default.fileExists(atPath: mixed.path) {
                saveMixed(mixed, original: original, audio: audio)
            } else {
                // The temporary export may have been cleared, but the original is already a work.
                await mix(original, audio: audio)
            }
        }
    }

    private func mix(_ original: URL, audio: URL) async {
        let started = CFAbsoluteTimeGetCurrent()
        let exportID = UUID()
        activeExportID = exportID
        defer { activeExportID = nil }
        do {
            let mixed = try await exportAudio(original, audio) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.activeExportID == exportID else { return }
                    self.progress = value
                }
            }
            Track.log(.exportFinished, ["ms": Track.ms(since: started), "ok": "yes"])
            saveMixed(mixed, original: original, audio: audio)
        } catch {
            NSLog("[Recording] music export failed: %@", error.localizedDescription)
            Track.log(.exportFinished, ["ms": Track.ms(since: started), "ok": "no"])
            recovery = .mix(original, audio: audio)
            issue = Issue(
                stage: .music,
                message: NSLocalizedString(
                    Self.isStorageFull(error)
                        ? "There is not enough free space to add music. Your original video is saved. Free up storage and retry, or keep the original video."
                        : "Your original video is saved without music. Retry adding music, or keep the original video.",
                    comment: ""
                )
            )
        }
    }

    private func saveMixed(_ mixed: URL, original: URL, audio: URL) {
        do {
            let saved = try save(mixed)
            // The original is removed only after its replacement has been saved successfully.
            if saved != original { removeOriginal(original) }
            complete(saved, hasMusic: true)
        } catch {
            failSaving(error, recovery: .saveMixed(mixed, original: original, audio: audio))
        }
    }

    private func failSaving(_ error: Error, recovery: Recovery) {
        NSLog("[Recording] save failed: %@", error.localizedDescription)
        self.recovery = recovery
        let message: String
        if Self.isStorageFull(error) {
            message = savedOriginal == nil
                ? "There is not enough free space to save. Your recorded file is kept on this device. Free up storage and retry."
                : "There is not enough free space to save the video with music. Your original video is still saved. Free up storage and retry, or keep the original video."
        } else {
            message = savedOriginal == nil
                ? "Your recorded file is kept on this device. Check available storage and retry saving."
                : "The video with music could not be saved. Your original video is still saved. Retry, or keep the original video."
        }
        issue = Issue(
            stage: .saving,
            message: NSLocalizedString(message, comment: "")
        )
    }

    private static func isStorageFull(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<5 {
            guard let error = current else { return false }
            if (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue)
                || (error.domain == AVFoundationErrorDomain && error.code == AVError.diskFull.rawValue)
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private func complete(_ url: URL, hasMusic: Bool) {
        recovery = nil
        Track.log(.workSaved, ["music": hasMusic ? "yes" : "no"])
        finished = FinishedWork(url: url)
    }
}
