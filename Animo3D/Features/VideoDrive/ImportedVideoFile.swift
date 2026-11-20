import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers

/// Owns only our copy. The Photos picker is free to remove its file once the transfer returns.
nonisolated final class ImportedVideoFile: Transferable, Sendable {
    let url: URL

    private init(url: URL) {
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copyTask = Task.detached(priority: .userInitiated) {
                try Self.copy(from: received.file)
            }
            return try await withTaskCancellationHandler {
                let file = try await copyTask.value
                try Task.checkCancellation()
                return file
            } onCancel: {
                copyTask.cancel()
            }
        }
    }

    static func copy(
        from source: URL,
        directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("VideoImports")
    ) throws -> ImportedVideoFile {
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let suffix = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let destination = directory.appendingPathComponent("src_\(UUID().uuidString).\(suffix)")
        do {
            // File copying keeps video bytes out of the Swift heap, including for large iCloud videos.
            try manager.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            return ImportedVideoFile(url: destination)
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func validate() async throws {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            guard !tracks.isEmpty, playable, duration.seconds.isFinite, duration.seconds > 0 else {
                throw VideoImportError.unplayable
            }
        } catch {
            try Task.checkCancellation()
            throw VideoImportError.unplayable
        }
    }
}

nonisolated enum VideoImportError: Error {
    case unreadable
    case unplayable

    static func message(for error: Error) -> String {
        let failure = error as NSError
        if (failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC)) {
            return "There is not enough free space to import this video. Free up storage and try again."
        }
        if let nested = failure.userInfo[NSUnderlyingErrorKey] as? Error {
            return message(for: nested)
        }
        if let failure = error as? VideoImportError, failure == .unplayable {
            return "This file doesn't contain a playable video. Choose another video."
        }
        return "The video couldn't be imported. Please try again."
    }
}
