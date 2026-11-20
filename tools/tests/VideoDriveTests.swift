import XCTest
import SwiftUI
import AVFoundation
import CoreVideo

@MainActor
final class VideoDriveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        PoseLandmarkerService.control.reset()
    }

    override func tearDownWithError() throws {
        PoseLandmarkerService.control.release()
        try FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for the video operation")
    }

    private func makeMovie(_ name: String = "source.mp4") async throws -> URL {
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
        for frame in 0..<60 {
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
                repeating: UInt8(frame * 3),
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

    private func select(_ video: URL, in store: VideoImportStore) async throws -> URL {
        let directory = root.appendingPathComponent("owned")
        store.importVideo { try ImportedVideoFile.copy(from: video, directory: directory) }
        try await waitUntil { !store.isImporting }
        XCTAssertNil(store.errorMessage)
        return try XCTUnwrap(store.videoURL)
    }

    func testFileTransferCopiesLargeVideoWithoutReadingItIntoData() throws {
        let original = root.appendingPathComponent("large.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: original.path, contents: nil))
        let handle = try FileHandle(forWritingTo: original)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        var copy: ImportedVideoFile? = try ImportedVideoFile.copy(from: original, directory: root.appendingPathComponent("owned"))
        let copyURL = try XCTUnwrap(copy?.url)
        XCTAssertEqual(try copyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, 512 * 1024 * 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        copy = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testValidReplacementRemovesOldCopyOnlyAfterSuccess() async throws {
        let first = try await makeMovie()
        let second = try await makeMovie("second.mp4")
        let store = VideoImportStore()
        let old = try await select(first, in: store)
        let new = try await select(second, in: store)
        XCTAssertNotEqual(old, new)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    func testFailedReplacementPreservesOriginalAndCanRetry() async throws {
        let video = try await makeMovie()
        let store = VideoImportStore()
        let old = try await select(video, in: store)
        let blocker = root.appendingPathComponent("blocked")
        try Data("blocked directory".utf8).write(to: blocker)
        store.importVideo { try ImportedVideoFile.copy(from: video, directory: blocker) }
        try await waitUntil { !store.isImporting }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.videoURL, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))

        try FileManager.default.removeItem(at: blocker)
        store.retry()
        try await waitUntil { !store.isImporting }
        XCTAssertNil(store.errorMessage)
        XCTAssertNotEqual(store.videoURL, old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testInvalidVideoPreservesOriginalAndDeletesRejectedCopy() async throws {
        let video = try await makeMovie()
        let invalid = root.appendingPathComponent("invalid.mov")
        try Data("not a movie".utf8).write(to: invalid)
        let store = VideoImportStore()
        let old = try await select(video, in: store)
        let directory = root.appendingPathComponent("owned")
        store.importVideo { try ImportedVideoFile.copy(from: invalid, directory: directory) }
        try await waitUntil { !store.isImporting }
        XCTAssertEqual(store.errorMessage, VideoImportError.message(for: VideoImportError.unplayable))
        XCTAssertEqual(store.videoURL, old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testNilTransferShowsErrorWithoutDroppingSelection() async throws {
        let video = try await makeMovie()
        let store = VideoImportStore()
        let old = try await select(video, in: store)
        store.importVideo { nil }
        try await waitUntil { !store.isImporting }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.videoURL, old)
    }

    func testCancelledImportCannotReplaceOriginalOrShowLateError() async throws {
        let video = try await makeMovie()
        let store = VideoImportStore()
        let old = try await select(video, in: store)
        let gate = VideoTestGate()
        let started = expectation(description: "Candidate copied")
        let directory = root.appendingPathComponent("owned")
        store.importVideo {
            let file = try ImportedVideoFile.copy(from: video, directory: directory)
            started.fulfill()
            await gate.wait()
            return file
        }
        await fulfillment(of: [started], timeout: 2)
        store.cancelImport()
        await gate.open()
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 1 }
        XCTAssertEqual(store.videoURL, old)
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.errorMessage)
    }

    func testLatestImportWinsWhenAnOlderTransferReturnsLate() async throws {
        let video = try await makeMovie()
        let store = VideoImportStore()
        let gate = VideoTestGate()
        let started = expectation(description: "Old transfer copied")
        let directory = root.appendingPathComponent("owned")
        store.importVideo {
            let file = try ImportedVideoFile.copy(from: video, directory: directory)
            started.fulfill()
            await gate.wait()
            return file
        }
        await fulfillment(of: [started], timeout: 2)
        let newest = try await select(video, in: store)
        await gate.open()
        try await waitUntil { (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) == 1 }
        XCTAssertEqual(store.videoURL, newest)
        XCTAssertNil(store.errorMessage)
    }

    func testStorageErrorIncludesNestedOutOfSpaceFailure() {
        let wrapped = NSError(domain: "Import", code: 1, userInfo: [
            NSUnderlyingErrorKey: CocoaError(.fileWriteOutOfSpace)
        ])
        XCTAssertTrue(VideoImportError.message(for: wrapped).contains("free space"))
    }

    func testStopDuringMetadataPreparationCannotRestartPlayer() async throws {
        let video = try await makeMovie()
        let gate = VideoTestGate()
        let started = expectation(description: "Metadata preparation started")
        let model = VideoPoseViewModel(orientationLoader: { _ in
            started.fulfill()
            await gate.wait()
            return .up
        })
        defer { model.stop() }
        model.load(url: video)
        await fulfillment(of: [started], timeout: 2)
        model.stop()
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.status, L("Select a video"))
    }

    func testLatestVideoWinsWhenMetadataForOldVideoReturnsLate() async throws {
        let first = try await makeMovie()
        let second = try await makeMovie("second.mp4")
        let gate = VideoTestGate()
        let started = expectation(description: "Old metadata started")
        let model = VideoPoseViewModel(orientationLoader: { asset in
            if (asset as? AVURLAsset)?.url == first {
                started.fulfill()
                await gate.wait()
            }
            return .up
        })
        defer { model.stop() }
        model.load(url: first)
        await fulfillment(of: [started], timeout: 2)
        model.load(url: second)
        try await waitUntil { model.isRunning }
        await gate.open()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, second)
        XCTAssertTrue(model.isRunning)
    }

    func testStoppedSessionDropsLateInferenceResult() async throws {
        let video = try await makeMovie()
        let started = expectation(description: "Inference started")
        PoseLandmarkerService.control.reset(blockFirst: true) { if $0 == 1 { started.fulfill() } }
        let model = VideoPoseViewModel()
        let world = expectation(description: "Stopped session must not drive the character")
        world.isInverted = true
        model.onWorld = { _ in world.fulfill() }
        defer {
            model.stop()
            PoseLandmarkerService.control.release()
        }
        model.load(url: video)
        await fulfillment(of: [started], timeout: 5)
        model.stop()
        PoseLandmarkerService.control.release()
        await fulfillment(of: [world], timeout: 0.3)
        XCTAssertTrue(model.landmarks.isEmpty)
        XCTAssertNil(model.player.currentItem)
        XCTAssertFalse(model.isRunning)
    }

    func testSwitchingDuringInferenceDropsOldResultAndKeepsDetectorSerial() async throws {
        let first = try await makeMovie()
        let second = try await makeMovie("second.mp4")
        let started = expectation(description: "Old inference started")
        PoseLandmarkerService.control.reset(blockFirst: true) { if $0 == 1 { started.fulfill() } }
        let model = VideoPoseViewModel()
        var delivered: [Float] = []
        model.onWorld = { if let value = $0.first?.x { delivered.append(value) } }
        defer {
            model.stop()
            PoseLandmarkerService.control.release()
        }
        model.load(url: first)
        await fulfillment(of: [started], timeout: 5)
        model.load(url: second)
        try await waitUntil { model.isRunning }
        PoseLandmarkerService.control.release()
        try await waitUntil { !delivered.isEmpty }
        XCTAssertFalse(delivered.contains(1))
        XCTAssertEqual(PoseLandmarkerService.control.snapshot.maximumActive, 1)
        XCTAssertEqual((model.player.currentItem?.asset as? AVURLAsset)?.url, second)
    }

    func testQueuedPlaybackLoopCannotRestartAfterStop() async throws {
        let video = try await makeMovie()
        let model = VideoPoseViewModel()
        defer { model.stop() }
        model.load(url: video)
        try await waitUntil { model.isRunning }
        let item = try XCTUnwrap(model.player.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        model.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isRunning)
        XCTAssertNil(model.player.currentItem)
        XCTAssertEqual(model.player.rate, 0)
    }

    func testInferenceTimestampsStayMonotonicAcrossPlaybackLoops() async throws {
        let video = try await makeMovie()
        let model = VideoPoseViewModel()
        defer { model.stop() }
        model.load(url: video)
        try await waitUntil { PoseLandmarkerService.control.snapshot.calls >= 2 }
        try await Task.sleep(nanoseconds: 2_200_000_000)
        let snapshot = PoseLandmarkerService.control.snapshot
        XCTAssertGreaterThan(snapshot.calls, 3)
        XCTAssertEqual(snapshot.maximumActive, 1)
        XCTAssertEqual(snapshot.timestamps, snapshot.timestamps.sorted())
        XCTAssertEqual(snapshot.timestamps.count, Set(snapshot.timestamps).count)
        XCTAssertTrue(model.isRunning)
    }

    func testViewModelIsReleasedWhileOldMetadataIsStillPending() async throws {
        let video = try await makeMovie()
        let gate = VideoTestGate()
        let started = expectation(description: "Metadata request pending")
        var model: VideoPoseViewModel? = VideoPoseViewModel(orientationLoader: { _ in
            started.fulfill()
            await gate.wait()
            return .up
        })
        weak var weakModel = model
        model?.load(url: video)
        await fulfillment(of: [started], timeout: 2)
        model = nil
        XCTAssertNil(weakModel)
        await gate.open()
    }

    func testImportFailureAlertOnDevice() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for language in ["en", "de"] {
            let source = VideoImportStore()
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView:
                Text("Select Video")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .videoImportFeedback(source: source)
                    .environment(\.locale, Locale(identifier: language))
            )
            window.rootViewController = controller
            window.makeKeyAndVisible()
            source.importVideo { throw CocoaError(.fileWriteOutOfSpace) }
            try await waitUntil { source.errorMessage != nil }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertNotNil(controller.presentedViewController)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Video-Import-Failure-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            controller.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }
}
