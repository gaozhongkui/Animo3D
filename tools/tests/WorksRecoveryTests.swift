import XCTest
import SwiftUI
import AVFoundation
import ImageIO

@MainActor
final class WorksRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the work operation")
    }
    private func makeMovie(_ name: String = "source.mp4", frameCount: Int = 60) async throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ])
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
            try await waitUntil { input.isReadyForMoreMediaData || writer.status == .failed }
            if let error = writer.error { throw error }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(
                kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &buffer
            ), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
            address.initializeMemory(
                as: UInt8.self,
                repeating: UInt8((frame * 3) % 255),
                count: CVPixelBufferGetBytesPerRow(pixelBuffer) * 64
            )
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func file(_ name: String = "source.mp4") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func testRealPreviewReadsThumbnailDurationAndDate() async throws {
        let video = try await makeMovie()
        let preview = try await WorkPreviewCache().preview(for: video)
        XCTAssertNotNil(preview.thumbnail)
        XCTAssertGreaterThan(preview.duration, 1.5)
        XCTAssertEqual(preview.durationText, "00:02")
        XCTAssertNotNil(preview.date)
    }

    func testCacheCoalescesRequestsAndAvoidsRepeatedDecoding() async throws {
        let video = try file()
        let gate = WorkTestGate()
        let probe = WorkDecodeProbe()
        let cache = WorkPreviewCache { _ in
            _ = await probe.begin(onMainThread: Thread.isMainThread)
            await gate.wait()
            await probe.finish()
            return WorkPreview(thumbnail: nil, duration: 3, date: nil)
        }
        let first = Task { try await cache.preview(for: video) }
        let second = Task { try await cache.preview(for: video) }
        try await waitUntil { await probe.count == 1 }
        await gate.open()
        _ = try await first.value
        _ = try await second.value
        _ = try await cache.preview(for: video)
        let count = await probe.count
        let mainThread = await probe.usedMainThread
        XCTAssertEqual(count, 1)
        XCTAssertFalse(mainThread)
    }

    func testCacheLimitsConcurrentDecodes() async throws {
        let videos = try (0..<5).map { try file("\($0).mp4") }
        let gate = WorkTestGate()
        let probe = WorkDecodeProbe()
        let cache = WorkPreviewCache(concurrencyLimit: 2) { _ in
            _ = await probe.begin()
            await gate.wait()
            await probe.finish()
            return WorkPreview(thumbnail: nil, duration: 1, date: nil)
        }
        let tasks = videos.map { video in Task { try await cache.preview(for: video) } }
        try await waitUntil { await probe.active == 2 }
        await gate.open()
        for task in tasks { _ = try await task.value }
        let maximum = await probe.maximum
        let count = await probe.count
        XCTAssertEqual(maximum, 2)
        XCTAssertEqual(count, 5)
    }

    func testChangedLocalFileInvalidatesTheCachedPreview() async throws {
        let video = try file()
        let probe = WorkDecodeProbe()
        let cache = WorkPreviewCache { _ in
            let number = await probe.begin()
            await probe.finish()
            return WorkPreview(thumbnail: nil, duration: Double(number), date: nil)
        }
        let first = try await cache.preview(for: video)
        try Data("a different recording".utf8).write(to: video)
        let second = try await cache.preview(for: video)
        XCTAssertEqual(first.duration, 1)
        XCTAssertEqual(second.duration, 2)
    }

    func testCancelledThumbnailRequestReleasesItsDecodeSlot() async throws {
        let first = try file("first.mp4")
        let second = try file("second.mp4")
        let started = expectation(description: "Offscreen thumbnail started")
        let cache = WorkPreviewCache(concurrencyLimit: 1) { url in
            if url == first {
                started.fulfill()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return WorkPreview(thumbnail: nil, duration: 2, date: nil)
        }
        let old = Task { try await cache.preview(for: first) }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        let visible = try await cache.preview(for: second)
        XCTAssertEqual(visible.duration, 2)
        guard case .failure(let error) = await old.result else { return XCTFail("Cancelled decode succeeded") }
        XCTAssertTrue(error is CancellationError)
    }

    func testInvalidationCancelsAnOldDecodeAndDoesNotCacheItsResult() async throws {
        let video = try file()
        let gate = WorkTestGate()
        let probe = WorkDecodeProbe()
        let cache = WorkPreviewCache { _ in
            let number = await probe.begin()
            if number == 1 { await gate.wait() }
            await probe.finish()
            return WorkPreview(thumbnail: nil, duration: Double(number), date: nil)
        }
        let first = Task { try await cache.preview(for: video) }
        try await waitUntil { await probe.count == 1 }
        await cache.invalidate(video)
        await gate.open()
        guard case .failure(let error) = await first.result else { return XCTFail("Old decode succeeded") }
        XCTAssertTrue(error is CancellationError)
        let newest = try await cache.preview(for: video)
        XCTAssertEqual(newest.duration, 2)
    }

    func testGalleryReuseRejectsThePreviousURLAndClearsOldLabels() async throws {
        let first = try file("first.mp4")
        let second = try file("second.mp4")
        let gate = WorkTestGate()
        let started = expectation(description: "Old gallery decode started")
        let cache = WorkPreviewCache { url in
            if url == first {
                started.fulfill()
                await gate.wait()
            }
            return WorkPreview(thumbnail: nil, duration: url == first ? 5 : 12, date: nil)
        }
        let cell = GalleryWorkCell(frame: CGRect(x: 0, y: 0, width: 160, height: 200))
        cell.configure(url: first, cache: cache)
        await fulfillment(of: [started], timeout: 2)
        cell.configure(url: second, cache: cache)
        let labels = cell.contentView.subviews.compactMap { $0 as? UILabel }
        try await waitUntil { labels.first?.text == "00:12" }
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(labels.first?.text, "00:12")
        cell.prepareForReuse()
        XCTAssertNil(labels.first?.text)
        XCTAssertNil(cell.contentView.subviews.compactMap { $0 as? UIImageView }.first?.image)
    }

    func testDeleteFailurePreservesTheCreationAndRetryWorksAfterAlertDismissal() async throws {
        let manager = DeleteFailingFileManager()
        let store = WorksStore(directory: root.appendingPathComponent("works"), draftsDirectory: root, fileManager: manager)
        let video = try store.add(from: file())
        let model = WorkDetailModel(url: video, removeWork: { try store.delete($0) })
        defer { model.deactivate() }
        model.activate()
        model.delete()
        XCTAssertFalse(model.deleted)
        XCTAssertEqual(model.issue?.action, .deletion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        XCTAssertEqual(store.works, [video])
        model.issue = nil // Native alerts can dismiss their binding before invoking the action.
        manager.shouldFail = false
        model.retry()
        XCTAssertTrue(model.deleted)
        XCTAssertNil(model.issue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertTrue(store.works.isEmpty)
    }

    func testDeletingAnAlreadyMissingCreationIsIdempotent() throws {
        let store = WorksStore(directory: root.appendingPathComponent("works"), draftsDirectory: root)
        XCTAssertNoThrow(try store.delete(root.appendingPathComponent("missing.mp4")))
        XCTAssertTrue(store.works.isEmpty)
    }

    func testSharePreparationCannotPresentAfterTheDetailIsClosed() async throws {
        let video = try await makeMovie()
        let gate = WorkTestGate()
        let started = expectation(description: "Share preview started")
        let returned = expectation(description: "Share preview finished late")
        let model = WorkDetailModel(url: video, loadPreview: { _ in
            started.fulfill()
            await gate.wait()
            returned.fulfill()
            return WorkPreview(thumbnail: nil, duration: 2, date: nil)
        })
        model.activate()
        model.prepareShare()
        await fulfillment(of: [started], timeout: 2)
        model.deactivate()
        await gate.open()
        await fulfillment(of: [returned], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.share)
        XCTAssertFalse(model.preparingShare)
        XCTAssertNil(model.player.currentItem)
    }

    func testLateGIFFinishAndProgressAreDiscardedAndTemporaryFileIsRemoved() async throws {
        let video = try file()
        let directory = root.appendingPathComponent("gifs")
        let gate = WorkTestGate()
        let started = expectation(description: "GIF worker started")
        let model = WorkDetailModel(url: video, exportGIF: { _, progress in
            let output = try makeOwnedTestGIF(in: directory)
            started.fulfill()
            await gate.wait()
            progress(0.9)
            return output
        })
        model.activate()
        model.prepareGIF()
        await fulfillment(of: [started], timeout: 2)
        model.deactivate()
        await gate.open()
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 0 }
        XCTAssertNil(model.share)
        XCTAssertNil(model.issue)
        XCTAssertFalse(model.preparingGIF)
        XCTAssertEqual(model.gifProgress, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testCancelledGIFCannotReplaceANewerOperationOrItsError() async throws {
        let video = try file()
        let directory = root.appendingPathComponent("gifs")
        let gate = WorkTestGate()
        let probe = WorkDecodeProbe()
        let started = expectation(description: "First GIF export started")
        let model = WorkDetailModel(url: video, exportGIF: { _, progress in
            let number = await probe.begin()
            if number > 1 { throw GIFExportError.writeFailed }
            let output = try makeOwnedTestGIF(in: directory)
            started.fulfill()
            await gate.wait()
            progress(1)
            return output
        })
        defer { model.deactivate() }
        model.activate()
        model.prepareGIF()
        await fulfillment(of: [started], timeout: 2)
        model.cancelGIF()
        model.prepareGIF()
        try await waitUntil { model.issue != nil }
        let message = model.issue?.message
        await gate.open()
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 0 }
        XCTAssertEqual(model.issue?.message, message)
        XCTAssertEqual(model.gifProgress, 0)
        XCTAssertNil(model.share)
    }

    func testGIFCanRetryAfterFailureWithoutChangingTheSource() async throws {
        let video = try file()
        let directory = root.appendingPathComponent("gifs")
        let probe = WorkDecodeProbe()
        let model = WorkDetailModel(url: video, exportGIF: { _, _ in
            let number = await probe.begin()
            if number == 1 { throw GIFExportError.frameFailed }
            return try makeOwnedTestGIF(in: directory)
        })
        defer {
            model.deactivate()
            model.share = nil
        }
        model.activate()
        model.prepareGIF()
        try await waitUntil { model.issue != nil }
        XCTAssertEqual(model.issue?.action, .gif)
        model.issue = nil
        model.retry()
        try await waitUntil { model.share != nil }
        XCTAssertFalse(model.preparingGIF)
        XCTAssertNil(model.issue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testShareControllerItemKeepsGIFAliveUntilItReleasesTheItem() async throws {
        let video = try file()
        let directory = root.appendingPathComponent("gifs")
        let model = WorkDetailModel(url: video, exportGIF: { _, _ in try makeOwnedTestGIF(in: directory) })
        model.activate()
        model.prepareGIF()
        try await waitUntil { model.share != nil }
        var activityItem = model.share?.item
        model.deactivate()
        model.share = nil
        withExtendedLifetime(activityItem) {
            XCTAssertEqual(try? FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        }
        activityItem = nil
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 0 }
    }

    func testOldPlaybackLoopCannotRestartAfterDeactivation() async throws {
        let video = try await makeMovie()
        let model = WorkDetailModel(url: video)
        model.activate()
        let item = try XCTUnwrap(model.player.currentItem)
        model.activate()
        XCTAssertTrue(model.player.currentItem === item)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        model.deactivate()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testRealGIFExportProducesTheExpectedFramesAndCleansUp() async throws {
        let video = try await makeMovie()
        var gif: ExportedGIF? = try await GIFExporter.convertToGIF(videoURL: video, maxDimension: 64, fps: 5, durationLimit: 0.3)
        let url = try XCTUnwrap(gif?.url)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        gif = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRealGIFExportHonorsTheExistingSixSecondLimit() async throws {
        let video = try await makeMovie(frameCount: 240)
        let gif = try await GIFExporter.convertToGIF(videoURL: video, maxDimension: 64, fps: 2)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(gif.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(image), 12)
    }

    func testCancelledNativeGIFExportRemovesItsPartialFile() async throws {
        let video = try await makeMovie()
        let directory = root.appendingPathComponent("gifs")
        let task = Task {
            try await GIFExporter.convertToGIF(videoURL: video, directory: directory) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        guard case .failure(let error) = await task.result else { return XCTFail("Cancelled GIF succeeded") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testInvalidVideoCannotProduceASuccessfulOrPartialGIF() async throws {
        let video = try file("broken.mov")
        let directory = root.appendingPathComponent("gifs")
        do {
            _ = try await GIFExporter.convertToGIF(videoURL: video, directory: directory)
            XCTFail("Corrupt video was accepted")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0, 0)
    }

    func testGIFStorageFailurePreservesTheSourceAndOffersRetry() async throws {
        let video = try file()
        let model = WorkDetailModel(url: video, exportGIF: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        defer { model.deactivate() }
        model.activate()
        model.prepareGIF()
        try await waitUntil { model.issue != nil }
        XCTAssertTrue(model.issue?.message.contains("free space") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testFailureAlertsInEnglishAndGerman() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for language in ["en", "de"] {
            for deleteFailure in [true, false] {
                let video = try file(UUID().uuidString + ".mp4")
                let model = WorkDetailModel(
                    url: video,
                    exportGIF: { _, _ in throw GIFExportError.writeFailed },
                    removeWork: { _ in throw CocoaError(.fileWriteNoPermission) }
                )
                let window = UIWindow(windowScene: scene)
                let controller = UIHostingController(rootView:
                    Text("My Creations")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .workDetailFeedback(model: model)
                        .environment(\.locale, Locale(identifier: language))
                )
                window.rootViewController = controller
                window.makeKeyAndVisible()
                model.activate()
                if deleteFailure { model.delete() } else { model.prepareGIF() }
                try await waitUntil { model.issue != nil }
                try await Task.sleep(nanoseconds: 250_000_000)
                XCTAssertNotNil(controller.presentedViewController)
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Work-\(deleteFailure ? "delete" : "gif")-failure-\(language)"
                attachment.lifetime = .keepAlways
                add(attachment)
                controller.dismiss(animated: false)
                model.deactivate()
                window.isHidden = true
                window.rootViewController = nil
            }
        }
    }
}
