import XCTest
import SwiftUI
import SceneKit
import AVFoundation

@MainActor
final class RecordingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String = "work_original.mp4") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("recorded video".utf8).write(to: url)
        return url
    }

    private func makeStore() -> WorksStore {
        WorksStore(
            directory: root.appendingPathComponent("works"),
            draftsDirectory: root.appendingPathComponent("drafts")
        )
    }

    func testFailedSavePreservesSourceAndCanRetry() throws {
        let source = try makeFile()
        let destination = try makeFile("blocked")
        let store = WorksStore(directory: destination, draftsDirectory: root.appendingPathComponent("drafts"))
        XCTAssertThrowsError(try store.add(from: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: destination)
        let saved = try store.add(from: source)
        XCTAssertEqual(try Data(contentsOf: saved), Data("recorded video".utf8))
        XCTAssertEqual(store.works, [saved])
    }

    func testCompletedDraftIsRecoveredOnceAndUnfinishedCaptureIsIgnored() throws {
        let drafts = root.appendingPathComponent("drafts")
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        let completed = drafts.appendingPathComponent("work_completed.mp4")
        let unfinished = drafts.appendingPathComponent("work_unfinished.recording")
        try Data("complete".utf8).write(to: completed)
        try Data("partial".utf8).write(to: unfinished)
        let store = makeStore()
        XCTAssertEqual(store.works.count, 1)
        let recovered = try store.add(from: completed)
        store.reload()
        XCTAssertEqual(store.works, [recovered])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unfinished.path))
    }

    func testOriginalIsSavedBeforeMusicExportFailure() async throws {
        let source = try makeFile()
        let store = makeStore()
        let output = RecordingOutput(
            save: { try store.add(from: $0) },
            exportAudio: { original, _, _ in
                XCTAssertTrue(store.works.contains(original))
                XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
                throw CocoaError(.fileReadCorruptFile)
            }
        )
        await output.process(.success(source), audio: root.appendingPathComponent("music.m4a"))
        XCTAssertEqual(output.issue?.stage, .music)
        XCTAssertNil(output.finished)
        XCTAssertTrue(output.canRetry)
        XCTAssertTrue(output.canKeepOriginal)
        XCTAssertEqual(store.works.count, 1)
        XCTAssertFalse(output.isProcessing)
    }

    func testRetryMusicAndRemoveOriginalOnlyAfterReplacementIsSaved() async throws {
        let source = try makeFile()
        let mixed = try makeFile("mixed.mp4")
        let store = makeStore()
        var attempts = 0
        let output = RecordingOutput(
            save: { try store.add(from: $0) },
            removeOriginal: { store.delete($0) },
            exportAudio: { _, _, _ in
                attempts += 1
                if attempts == 1 { throw CocoaError(.fileReadCorruptFile) }
                return mixed
            }
        )
        await output.process(.success(source), audio: root.appendingPathComponent("music.m4a"))
        let original = try XCTUnwrap(output.savedOriginal)
        await output.retry()
        let saved = try XCTUnwrap(output.finished?.url)
        XCTAssertNil(output.issue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(store.works, [saved])
        XCTAssertEqual(attempts, 2)
    }

    func testFailedMixedSaveKeepsBothFilesAndRetriesWithoutRemixing() async throws {
        let source = try makeFile()
        let mixed = try makeFile("mixed.mp4")
        let store = makeStore()
        var saves = 0
        var exports = 0
        let output = RecordingOutput(
            save: {
                saves += 1
                if saves == 2 { throw CocoaError(.fileWriteOutOfSpace) }
                return try store.add(from: $0)
            },
            removeOriginal: { store.delete($0) },
            exportAudio: { _, _, _ in
                exports += 1
                return mixed
            }
        )
        await output.process(.success(source), audio: root.appendingPathComponent("music.m4a"))
        let original = try XCTUnwrap(output.savedOriginal)
        XCTAssertEqual(output.issue?.stage, .saving)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixed.path))
        await output.retry()
        XCTAssertNotNil(output.finished)
        XCTAssertEqual(exports, 1)
        XCTAssertEqual(store.works.count, 1)
    }

    func testInitialSaveFailureCanBeRetried() async throws {
        let source = try makeFile()
        let store = makeStore()
        var failSave = true
        let output = RecordingOutput(save: {
            if failSave { throw CocoaError(.fileWriteOutOfSpace) }
            return try store.add(from: $0)
        })
        await output.process(.success(source))
        XCTAssertEqual(output.issue?.stage, .saving)
        XCTAssertEqual(
            output.issue?.message,
            NSLocalizedString("There is not enough free space to save. Your recorded file is kept on this device. Free up storage and retry.", comment: "")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(output.canKeepOriginal)
        failSave = false
        await output.retry()
        XCTAssertNotNil(output.finished)
        XCTAssertNil(output.issue)
    }

    func testKeepOriginalAfterMusicFailure() async throws {
        let store = makeStore()
        let output = RecordingOutput(
            save: { try store.add(from: $0) },
            exportAudio: { _, _, _ in throw CocoaError(.fileReadCorruptFile) }
        )
        await output.process(.success(try makeFile()), audio: root.appendingPathComponent("missing.m4a"))
        output.keepOriginal()
        XCTAssertEqual(output.finished?.url, output.savedOriginal)
        XCTAssertNil(output.issue)
        XCTAssertFalse(output.canRetry)
        XCTAssertEqual(store.works.count, 1)
    }

    func testRecordingFailureDoesNotOfferStaleOriginal() async throws {
        let store = makeStore()
        let output = RecordingOutput(save: { try store.add(from: $0) })
        await output.process(.success(try makeFile()))
        output.finished = nil
        output.reportRecordingError(RecordingError.noFrames)
        XCTAssertEqual(output.issue?.stage, .recording)
        XCTAssertFalse(output.canKeepOriginal)
        XCTAssertFalse(output.canRetry)
    }

    func testRecorderRejectsUnavailableScene() {
        let recorder = SceneViewRecorder(outputDirectory: root)
        XCTAssertThrowsError(try recorder.start(view: SCNView()))
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isFinishing)
    }

    func testRecordingErrorRecognizesNestedStorageFailure() {
        let output = RecordingOutput()
        output.reportRecordingError(NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.unknown.rawValue,
            userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteOutOfSpace)]
        ))
        XCTAssertEqual(
            output.issue?.message,
            NSLocalizedString("There is not enough free space to record. Free up storage and try again.", comment: "")
        )
    }

    func testImmediateStopRejectsEmptyMovieAndBlocksOverlappingCapture() async throws {
        let view = makeSceneView()
        let recorder = SceneViewRecorder(outputDirectory: root)
        try recorder.start(view: view)
        let result = await withCheckedContinuation { continuation in
            recorder.stop { continuation.resume(returning: $0) }
            XCTAssertTrue(recorder.isFinishing)
            do {
                try recorder.start(view: view)
                XCTFail("A capture must not start while the previous writer is finishing")
            } catch {}
        }
        XCTAssertThrowsError(try result.get())
        XCTAssertFalse(recorder.isFinishing)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func makeSceneView() -> SCNView {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 240, height: 320))
        let scene = SCNScene()
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(0, 0, 4)
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(SCNNode(geometry: SCNSphere(radius: 1)))
        view.scene = scene
        view.pointOfView = camera
        view.autoenablesDefaultLighting = true
        return view
    }

    private func recordMovie() async throws -> URL {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let view = makeSceneView()
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Let the preview render first, as it does before the user presses Record in the App.
        try await Task.sleep(nanoseconds: 400_000_000)
        let recorder = SceneViewRecorder(outputDirectory: root)
        try recorder.start(view: view)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let result = await withCheckedContinuation { continuation in
            recorder.stop { continuation.resume(returning: $0) }
        }
        let url = try result.get()
        XCTAssertEqual(url.pathExtension, "mp4")
        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.2, "The export fixture needs more than a few cold-render frames")
        return url
    }

    func testRecorderProducesPlayableMovie() async throws {
        let url = try await recordMovie()
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty)
    }

    func testMixerRejectsVideoWithoutAudioTrack() async throws {
        let original = try await recordMovie()
        do {
            _ = try await VideoAudioMixer.export(video: original, audio: original)
            XCTFail("A selected file without an audio track must not silently export without music")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testMixerExportsActualAudioAndPreservesOriginal() async throws {
        #if targetEnvironment(simulator)
        try XCTSkipIf(
            AVAssetExportSession.allExportPresets().isEmpty,
            "The simulator exposes no media export presets. Verify actual audio export on another runtime or a real device."
        )
        #endif
        let original = try await recordMovie()
        let audio = try XCTUnwrap(Bundle.main.url(forResource: "music_sample_beat", withExtension: "m4a"))
        let mixed = try await VideoAudioMixer.export(video: original, audio: audio)
        defer { try? FileManager.default.removeItem(at: mixed) }
        let tracks = try await AVURLAsset(url: mixed).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRecoveryAlerts() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for stage in [RecordingOutput.Issue.Stage.recording, .saving, .music] {
            let store = makeStore()
            let output = RecordingOutput(
                save: {
                    if stage == .saving { throw CocoaError(.fileWriteOutOfSpace) }
                    return try store.add(from: $0)
                },
                exportAudio: { _, _, _ in throw CocoaError(.fileReadCorruptFile) }
            )
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(rootView:
                Text("Recording preview")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .recordingFeedback(output: output)
            )
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 100_000_000)
            switch stage {
            case .recording:
                output.reportRecordingError(RecordingError.noFrames)
            case .saving:
                await output.process(.success(try makeFile()))
            case .music:
                await output.process(.success(try makeFile()), audio: root.appendingPathComponent("missing"))
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertNotNil(controller.presentedViewController)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Recording-\(stage)"
            attachment.lifetime = .keepAlways
            add(attachment)
            controller.dismiss(animated: false)
            window.isHidden = true
        }
    }
}
