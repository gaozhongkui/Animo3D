import XCTest
import SwiftUI

@MainActor
final class LaunchTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.rootViewController = nil
        window?.isHidden = true
        window = nil
        RemoteAssets.shared.state = .loading
        super.tearDown()
    }

    private func presentSplash(onFinish: @escaping () -> Void) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SplashView(isActive: Binding(
            get: { false },
            set: { if $0 { onFinish() } }
        )))
        self.window = window
        window.makeKeyAndVisible()
    }

    func testReadyCatalogDoesNotWaitForOldMinimumHold() async throws {
        RemoteAssets.shared.state = .ready
        let finished = expectation(description: "Ready catalog opens Home")
        try presentSplash { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 0.8)
    }

    func testCatalogBecomingReadyLeavesSplashPromptly() async throws {
        RemoteAssets.shared.state = .loading
        let finished = expectation(description: "New catalog opens Home without the old delay")
        try presentSplash { finished.fulfill() }
        try await Task.sleep(nanoseconds: 150_000_000)
        RemoteAssets.shared.state = .ready
        await fulfillment(of: [finished], timeout: 0.6)
    }

    func testSlowCatalogStillHasBoundedWait() async throws {
        RemoteAssets.shared.state = .loading
        let finished = expectation(description: "Network cannot trap the user on Splash")
        let started = Date()
        try presentSplash { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 6.8)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 5.9)
    }

    func testCancelledSplashDoesNotNavigateAfterDisappearing() async throws {
        RemoteAssets.shared.state = .loading
        var didFinish = false
        try presentSplash { didFinish = true }
        try await Task.sleep(nanoseconds: 150_000_000)
        window?.rootViewController = UIViewController()
        try await Task.sleep(nanoseconds: 150_000_000)
        RemoteAssets.shared.state = .ready
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(didFinish)
    }
}
