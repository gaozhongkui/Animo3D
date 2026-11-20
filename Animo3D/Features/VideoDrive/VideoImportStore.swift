import Combine
import Foundation

@MainActor
final class VideoImportStore: ObservableObject {
    typealias ImportOperation = @Sendable () async throws -> ImportedVideoFile?

    @Published private(set) var selection: ImportedVideoFile?
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    var videoURL: URL? { selection?.url }

    private var importTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastImport: ImportOperation?

    deinit { importTask?.cancel() }

    func importVideo(using operation: @escaping ImportOperation) {
        cancelImport()
        lastImport = operation
        let request = generation
        isImporting = true
        importTask = Task { [weak self] in
            do {
                guard let file = try await operation() else { throw VideoImportError.unreadable }
                try Task.checkCancellation()
                try await file.validate()
                guard !Task.isCancelled, let self, self.generation == request else { return }
                // Until validation succeeds, selection continues to own the original video.
                self.selection = file
                self.isImporting = false
                self.importTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.errorMessage = VideoImportError.message(for: error)
                self.isImporting = false
                self.importTask = nil
            }
        }
    }

    func retry() {
        guard let lastImport else { return }
        importVideo(using: lastImport)
    }

    func cancelImport() {
        generation = UUID()
        importTask?.cancel()
        importTask = nil
        isImporting = false
        errorMessage = nil
    }
}
