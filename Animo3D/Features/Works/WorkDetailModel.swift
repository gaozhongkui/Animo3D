import AVFoundation
import Combine
import UIKit

@MainActor
final class WorkDetailModel: ObservableObject {
    typealias PreviewLoader = @Sendable (URL) async throws -> WorkPreview
    typealias GIFExport = @Sendable (URL, @escaping @Sendable (Float) -> Void) async throws -> ExportedGIF

    struct Share: Identifiable {
        let id = UUID()
        let item: any UIActivityItemSource
    }

    struct Issue {
        enum Action { case deletion, gif }
        let id = UUID()
        let action: Action
        let message: String
        var title: String { action == .deletion ? "Could not delete video" : "Could not create GIF" }
    }

    let url: URL
    let player = AVPlayer()
    @Published private(set) var preparingShare = false
    @Published private(set) var preparingGIF = false
    @Published private(set) var gifProgress: Float = 0
    @Published private(set) var deleted = false
    @Published var share: Share?
    @Published var issue: Issue?

    private let loadPreview: PreviewLoader
    private let exportGIF: GIFExport
    private let removeWork: @MainActor (URL) throws -> Void
    private var isActive = false
    private var session = UUID()
    private var gifRequest: UUID?
    private var playerObserver: NSObjectProtocol?
    private var shareTask: Task<Void, Never>?
    private var gifTask: Task<Void, Never>?
    private var gif: ExportedGIF?
    private var videoShareItem: VideoShareItem?
    private var retryAction: Issue.Action?

    init(
        url: URL,
        loadPreview: @escaping PreviewLoader = { try await WorkPreviewCache.shared.preview(for: $0) },
        exportGIF: @escaping GIFExport = { url, progress in
            try await GIFExporter.convertToGIF(videoURL: url, onProgress: progress)
        },
        removeWork: @escaping @MainActor (URL) throws -> Void = { try WorksStore.shared.delete($0) }
    ) {
        self.url = url
        self.loadPreview = loadPreview
        self.exportGIF = exportGIF
        self.removeWork = removeWork
    }

    deinit {
        shareTask?.cancel()
        gifTask?.cancel()
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
    }

    func activate() {
        guard !deleted else { return }
        if !isActive {
            isActive = true
            session = UUID()
        }
        resumePlayback()
    }

    func deactivate() {
        isActive = false
        session = UUID()
        cancelOperations()
        if let playerObserver { NotificationCenter.default.removeObserver(playerObserver) }
        playerObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        videoShareItem = nil
        gif = nil
        issue = nil
        retryAction = nil
        // An activity item keeps its GIF alive until the system share controller releases it.
    }

    private func resumePlayback() {
        guard isActive, !deleted, share == nil else { return }
        if player.currentItem == nil {
            let item = AVPlayerItem(url: url)
            let request = session
            player.replaceCurrentItem(with: item)
            playerObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor in
                    guard let self, let item, self.isActive, self.share == nil,
                          self.session == request, self.player.currentItem === item else { return }
                    let finished = await self.player.seek(to: .zero)
                    guard finished, self.isActive, self.share == nil,
                          self.session == request, self.player.currentItem === item else { return }
                    self.player.play()
                }
            }
        }
        player.play()
    }

    func prepareShare() {
        guard isActive, !deleted, !preparingShare, !preparingGIF, share == nil else { return }
        issue = nil
        retryAction = nil
        if let videoShareItem {
            present(videoShareItem)
            return
        }
        let request = session
        let load = loadPreview
        let url = url
        preparingShare = true
        shareTask = Task { [weak self] in
            let preview = try? await load(url)
            guard !Task.isCancelled, let self, self.isActive, self.session == request else { return }
            let item = VideoShareItem(url: url, title: L("My Creation"), thumbnail: preview?.thumbnail)
            self.videoShareItem = item
            self.preparingShare = false
            self.shareTask = nil
            self.present(item)
        }
    }

    func prepareGIF() {
        guard isActive, !deleted, !preparingGIF, !preparingShare, share == nil else { return }
        issue = nil
        retryAction = nil
        if let gif, FileManager.default.fileExists(atPath: gif.url.path) {
            present(GIFShareItem(file: gif))
            return
        }
        let request = UUID()
        let activeSession = session
        gifRequest = request
        preparingGIF = true
        gifProgress = 0
        let export = exportGIF
        let url = url
        let reportProgress: @Sendable (Float) async -> Void = { [weak self] value in
            await self?.updateGIFProgress(value, request: request, session: activeSession)
        }
        gifTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return try await export(url) { value in
                    Task { await reportProgress(value) }
                }
            }
            do {
                let file = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.isActive,
                      self.session == activeSession, self.gifRequest == request else { return }
                self.gif = file
                self.preparingGIF = false
                self.gifRequest = nil
                self.gifTask = nil
                self.present(GIFShareItem(file: file))
                HapticManager.success()
            } catch {
                guard !Task.isCancelled, let self, self.isActive,
                      self.session == activeSession, self.gifRequest == request else { return }
                self.preparingGIF = false
                self.gifTask = nil
                self.gifRequest = nil
                self.retryAction = .gif
                self.issue = Issue(action: .gif, message: Self.gifMessage(for: error))
            }
        }
    }

    private func updateGIFProgress(_ value: Float, request: UUID, session: UUID) {
        guard isActive, self.session == session, gifRequest == request else { return }
        gifProgress = min(1, max(0, value))
    }

    private func present(_ item: any UIActivityItemSource) {
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        share = Share(item: item)
    }

    func shareDismissed() {
        share = nil
        resumePlayback()
    }

    func cancelGIF() {
        gifRequest = nil
        gifTask?.cancel()
        gifTask = nil
        preparingGIF = false
        gifProgress = 0
    }

    private func cancelOperations() {
        shareTask?.cancel()
        shareTask = nil
        preparingShare = false
        cancelGIF()
    }

    func delete() {
        guard isActive, !deleted else { return }
        cancelOperations()
        player.pause()
        issue = nil
        retryAction = nil
        do {
            try removeWork(url)
            deleted = true
            Track.log(.workDeleted)
            deactivate()
            Task { await WorkPreviewCache.shared.invalidate(url) }
        } catch {
            retryAction = .deletion
            issue = Issue(
                action: .deletion,
                message: "The video couldn't be deleted. It is still in My Creations. Please try again."
            )
            resumePlayback()
        }
    }

    func retry() {
        guard let retryAction else { return }
        switch retryAction {
        case .deletion: delete()
        case .gif: prepareGIF()
        }
    }

    private static func gifMessage(for error: Error) -> String {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain, failure.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return "There is not enough free space to create the GIF. Free up storage and try again."
        }
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error {
            return gifMessage(for: underlying)
        }
        switch error as? GIFExportError {
        case .invalidVideo:
            return "This video couldn't be opened. Try again or choose another creation."
        case .writeFailed:
            return "The GIF couldn't be saved. Check available storage and try again. Your video is unchanged."
        default:
            return "The GIF couldn't be created. Your video is unchanged. Please try again."
        }
    }
}

private final class GIFShareItem: NSObject, UIActivityItemSource {
    private let file: ExportedGIF
    init(file: ExportedGIF) { self.file = file }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { file.url }
    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType type: UIActivity.ActivityType?
    ) -> Any? { file.url }
}
