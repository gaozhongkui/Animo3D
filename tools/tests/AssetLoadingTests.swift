import XCTest
import SwiftUI

@MainActor
final class AssetLoadingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RemoteAssets.shared.reset()
    }

    func testOfflineModelShowsConnectionFailure() async {
        RemoteAssets.shared.resolveFile = { _ in throw URLError(.notConnectedToInternet) }
        let performer = DancePerformer()
        let succeeded = await performer.load(character: "character")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(performer.isReady)
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .character, reason: .offline))
    }

    func testRetryAfterNetworkRecoveryClearsFailureAndLoadsSameSelection() async {
        let performer = DancePerformer()
        RemoteAssets.shared.resolveFile = { _ in throw URLError(.timedOut) }
        _ = await performer.load(character: "character", dance: "dance")
        XCTAssertEqual(performer.loadFailure?.reason, .timedOut)

        RemoteAssets.shared.reset()
        let succeeded = await performer.load(character: "character", dance: "dance")
        XCTAssertTrue(succeeded)
        XCTAssertTrue(performer.isReady)
        XCTAssertTrue(performer.isAnimating)
        XCTAssertNil(performer.loadFailure)
    }

    func testDanceDownloadFailureDoesNotLeavePreviewReady() async {
        RemoteAssets.shared.resolveFile = { path in
            if path == "clip" { throw URLError(.networkConnectionLost) }
            return URL(fileURLWithPath: "/" + path)
        }
        let performer = DancePerformer()
        let succeeded = await performer.load(character: "character", dance: "dance")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(performer.isReady)
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .dance, reason: .offline))
        XCTAssertTrue(RemoteAssets.shared.evicted.isEmpty)
    }

    func testCorruptDanceIsEvictedAndRetryRecovers() async {
        RemoteAssets.shared.resolveFile = { path in
            URL(fileURLWithPath: path == "clip" ? "/invalid-clip" : "/model")
        }
        let performer = DancePerformer()
        _ = await performer.load(character: "character", dance: "dance")
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .dance, reason: .invalid))
        XCTAssertEqual(RemoteAssets.shared.evicted, ["clip"])

        RemoteAssets.shared.reset()
        let succeeded = await performer.load(character: "character", dance: "dance")
        XCTAssertTrue(succeeded)
        XCTAssertNil(performer.loadFailure)
    }

    func testCorruptModelIsEvictedAndRetryRecovers() async {
        RemoteAssets.shared.resolveFile = { _ in URL(fileURLWithPath: "/invalid-model") }
        let performer = DancePerformer()
        _ = await performer.load(character: "character")
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .character, reason: .invalid))
        XCTAssertEqual(RemoteAssets.shared.evicted, ["model"])

        RemoteAssets.shared.reset()
        let succeeded = await performer.load(character: "character")
        XCTAssertTrue(succeeded)
        XCTAssertNil(performer.loadFailure)
    }

    func testUnusableSkeletonDoesNotCountAsSuccessfulLoad() async {
        RemoteAssets.shared.resolveFile = { _ in URL(fileURLWithPath: "/invalid-skeleton") }
        let performer = DancePerformer()
        let succeeded = await performer.load(character: "character")
        XCTAssertFalse(succeeded)
        XCTAssertFalse(performer.isReady)
        XCTAssertEqual(performer.loadFailure?.reason, .invalid)
        XCTAssertEqual(RemoteAssets.shared.evicted, ["model"])
    }

    func testRemovedContentShowsUnavailableInsteadOfSpinner() async {
        let performer = DancePerformer()
        _ = await performer.load(character: "missing")
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .character, reason: .unavailable))
        _ = await performer.load(character: "character", dance: "missing")
        XCTAssertEqual(performer.loadFailure, AssetLoadingFailure(resource: .dance, reason: .unavailable))
        XCTAssertFalse(performer.isReady)
    }

    func testCancelledLoadNeverPublishesFailureOrMountsScene() async throws {
        RemoteAssets.shared.resolveFile = { _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return URL(fileURLWithPath: "/model")
        }
        let performer = DancePerformer()
        let task = Task { await performer.load(character: "character") }
        await Task.yield()
        task.cancel()
        performer.unload()
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertFalse(performer.isReady)
        XCTAssertFalse(performer.controller.isLoaded)
        XCTAssertNil(performer.loadFailure)
    }

    func testOldLoadCannotReplaceNewSelectionAfterReturningLate() async throws {
        let started = expectation(description: "Old request started")
        var continuation: CheckedContinuation<URL, Error>?
        RemoteAssets.shared.resolveFile = { path in
            if path == "model" {
                return try await withCheckedThrowingContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
            return URL(fileURLWithPath: "/" + path)
        }
        let performer = DancePerformer()
        let old = Task { await performer.load(character: "character") }
        await fulfillment(of: [started], timeout: 1)
        performer.unload()
        let succeeded = await performer.load(character: "other")
        XCTAssertTrue(succeeded)
        continuation?.resume(returning: URL(fileURLWithPath: "/model"))
        let oldSucceeded = await old.value
        XCTAssertFalse(oldSucceeded)
        XCTAssertEqual(performer.controller.characterRoot?.name, "other-model")
        XCTAssertTrue(performer.isReady)
        XCTAssertNil(performer.loadFailure)
    }

    func testAlreadyCancelledLoadDoesNotClearCurrentFailure() async {
        let performer = DancePerformer()
        RemoteAssets.shared.resolveFile = { _ in throw URLError(.notConnectedToInternet) }
        _ = await performer.load(character: "character")
        let failure = performer.loadFailure
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await performer.load(character: "other")
        }
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(performer.loadFailure, failure)
    }

    func testRenderTimeoutCanBeRetriedAndDismissed() async {
        let performer = DancePerformer()
        _ = await performer.load(character: "character")
        performer.reportRenderFailure()
        XCTAssertFalse(performer.isReady)
        XCTAssertEqual(performer.loadFailure?.reason, .rendering)
        let succeeded = await performer.load(character: "character")
        XCTAssertTrue(succeeded)
        XCTAssertNil(performer.loadFailure)
        performer.reportRenderFailure()
        performer.unload()
        XCTAssertNil(performer.loadFailure)
    }

    func testCancellingOneWaiterPreservesSharedDownloadForAnother() async throws {
        let started = expectation(description: "Shared download started")
        var continuation: CheckedContinuation<URL, Error>?
        let shared = Task<URL, Error> {
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let first = Task { try await AssetDownloadWaiter().value(of: shared) }
        let second = Task { try await AssetDownloadWaiter().value(of: shared) }
        await fulfillment(of: [started], timeout: 1)
        first.cancel()
        let firstResult = await first.result
        guard case .failure(let error) = firstResult else { return XCTFail("Cancelled waiter succeeded") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(shared.isCancelled)
        let url = URL(fileURLWithPath: "/downloaded-model")
        continuation?.resume(returning: url)
        let secondURL = try await second.value
        XCTAssertEqual(secondURL, url)
    }

    func testWaiterCancelledBeforeRegistrationDoesNotLoseCancellation() async {
        let shared = Task<URL, Error> { URL(fileURLWithPath: "/model") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AssetDownloadWaiter().value(of: shared)
        }
        let result = await task.result
        guard case .failure(let error) = result else { return XCTFail("Pre-cancelled wait succeeded") }
        XCTAssertTrue(error is CancellationError)
    }

    func testDownloadTimeoutAndServerFailuresHaveDifferentGuidance() {
        XCTAssertEqual(AssetLoadingFailure.download(URLError(.timedOut), resource: .dance).reason, .timedOut)
        XCTAssertEqual(AssetLoadingFailure.download(URLError(.badServerResponse), resource: .dance).reason, .download)
    }

    func testFailureScreenOnDeviceAndSmallScreenWithLongText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for largeText in [false, true] {
            let view = AssetLoadingFailureView(
                failure: AssetLoadingFailure(resource: .character, reason: largeText ? .invalid : .offline),
                onRetry: {},
                onClose: {}
            )
            .environment(\.locale, Locale(identifier: largeText ? "de" : "en"))
            .environment(\.dynamicTypeSize, largeText ? .accessibility2 : .large)
            let host = UIHostingController(rootView: view)
            if largeText { window.frame = CGRect(x: 0, y: 0, width: 375, height: 667) }
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 250_000_000)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = largeText ? "loading-error-small-german-large-text" : "loading-error-device"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
