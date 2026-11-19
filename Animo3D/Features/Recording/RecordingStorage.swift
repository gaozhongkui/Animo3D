import Foundation

/// In-progress captures stay outside purgeable caches. Only finished MP4s are recovered as works.
nonisolated enum RecordingStorage {
    static var draftsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordingDrafts", isDirectory: true)
    }

    static func makeCaptureURL(in directory: URL = draftsDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("work_\(UUID().uuidString).recording")
    }

    static func markCompleted(_ url: URL) -> URL {
        let completed = url.deletingPathExtension().appendingPathExtension("mp4")
        do {
            try FileManager.default.moveItem(at: url, to: completed)
            return completed
        } catch {
            // The movie has finished encoding. Keep its actual URL so saving can still be retried.
            NSLog("[RecordingStorage] could not mark capture complete: %@", error.localizedDescription)
            return url
        }
    }
}

nonisolated enum RecordingError: LocalizedError {
    case busy
    case sceneUnavailable
    case couldNotStart
    case noFrames
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .busy: return NSLocalizedString("The previous recording is still being saved.", comment: "")
        case .sceneUnavailable: return NSLocalizedString("The scene is not ready. Please try again.", comment: "")
        case .couldNotStart: return NSLocalizedString("Recording could not start. Please try again.", comment: "")
        case .noFrames: return NSLocalizedString("No video frames were recorded. Record for a little longer and try again.", comment: "")
        case .encodingFailed: return NSLocalizedString("The recording could not be completed. Please try again.", comment: "")
        }
    }
}
