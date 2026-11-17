import Foundation
import XCTest
import StoreKit
import StoreKitTest
import SwiftUI

// Compile the production store without Firebase in the isolated StoreKit test bundle.
@MainActor
enum Track {
    enum Event {
        case purchaseStarted, purchaseSucceeded, purchaseFailed, purchaseRestored, paywallShown
    }
    static func log(_ event: Event, _ parameters: [String: Any] = [:]) {}
    static func setPro(_ value: Bool) {}
}

final class ProStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var defaultsSuiteNames: [String] = []

    override func tearDown() {
        for name in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsSuiteNames.removeAll()
        super.tearDown()
    }

    func testLegacyPermanentCustomerKeepsLifetimeAccess() {
        let entitlement = ProEntitlement.cached(data: nil, legacyIsPro: true, at: now)
        XCTAssertEqual(entitlement?.plan, .lifetime)
        XCTAssertTrue(entitlement?.isActive(at: now.addingTimeInterval(100_000_000)) == true)
    }

    func testExpiredMonthlyCacheNeverBecomesPermanent() throws {
        let expired = ProEntitlement(plan: .monthly, expirationDate: now.addingTimeInterval(-1))
        let cached = ProEntitlement.cached(
            data: try JSONEncoder().encode(expired),
            legacyIsPro: true,
            at: now
        )
        XCTAssertNil(cached)
    }

    func testMonthlyCacheRequiresFutureExpiration() throws {
        let active = ProEntitlement(plan: .monthly, expirationDate: now.addingTimeInterval(60))
        XCTAssertEqual(
            ProEntitlement.cached(data: try JSONEncoder().encode(active), legacyIsPro: false, at: now),
            active
        )
        XCTAssertFalse(active.isActive(at: now.addingTimeInterval(60)))
        XCTAssertFalse(ProEntitlement(plan: .monthly, expirationDate: nil).isActive(at: now))
    }

    func testInvalidCacheDoesNotGrantLifetime() {
        XCTAssertNil(ProEntitlement.cached(data: Data("broken".utf8), legacyIsPro: true, at: now))
        XCTAssertNil(ProEntitlement.cached(data: nil, legacyIsPro: false, at: now))
    }

    @MainActor
    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "Animo3D")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        return session
    }

    @MainActor
    private func makeStore() -> ProStore {
        let suiteName = "ProStoreTests.\(UUID().uuidString)"
        defaultsSuiteNames.append(suiteName)
        return ProStore(defaults: UserDefaults(suiteName: suiteName)!, startsAutomatically: false)
    }

    @MainActor
    private func waitForTier(
        _ tier: ProPlan?,
        in store: ProStore,
        refresh: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // StoreKit test actions return before the client receives the resulting transaction.
        // Allow delivery to settle, rather than asserting against the previous cached receipt.
        for _ in 0..<50 {
            if refresh { await store.refreshEntitlements() }
            if store.activeTier == tier { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(store.activeTier, tier, file: file, line: line)
    }

    @MainActor
    func testBothProductsAndMonthlyPriceLoad() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = makeStore()
        await store.loadProducts()
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.products.count, 2)
        let monthly = try XCTUnwrap(store.monthly)
        XCTAssertEqual(monthly.type, .autoRenewable)
        XCTAssertEqual(monthly.price, Decimal(string: "0.99"))
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.unit, .month)
        XCTAssertEqual(monthly.subscription?.subscriptionPeriod.value, 1)
        XCTAssertEqual(store.lifetime?.type, .nonConsumable)
    }

    @MainActor
    func testMonthlyPurchaseExpires() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = makeStore()
        await store.loadProducts()
        let monthly = try XCTUnwrap(store.monthly)
        let purchased = await store.purchase(monthly)
        XCTAssertTrue(purchased)
        XCTAssertEqual(store.activeTier, .monthly)
        XCTAssertNotNil(store.entitlement?.expirationDate)

        try session.expireSubscription(productIdentifier: ProPlan.monthly.productID)
        await waitForTier(nil, in: store, refresh: true)
        XCTAssertFalse(store.isPro)
        XCTAssertNil(store.activeTier)
    }

    @MainActor
    func testLifetimeSurvivesMonthlyExpiration() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: ProPlan.monthly.productID)
        _ = try await session.buyProduct(identifier: ProPlan.lifetime.productID)
        let store = makeStore()
        await store.refreshEntitlements()
        XCTAssertEqual(store.activeTier, .lifetime)

        try session.expireSubscription(productIdentifier: ProPlan.monthly.productID)
        await store.refreshEntitlements()
        XCTAssertEqual(store.activeTier, .lifetime)
        XCTAssertNil(store.entitlement?.expirationDate)
    }

    @MainActor
    func testRefundRemovesMonthlyAccess() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: ProPlan.monthly.productID)
        let store = makeStore()
        await store.refreshEntitlements()
        XCTAssertTrue(store.isPro)

        try session.refundTransaction(identifier: UInt(transaction.id))
        await waitForTier(nil, in: store)
        XCTAssertFalse(store.isPro)
    }

    @MainActor
    func testActiveSubscriberCannotBuyAnotherPlan() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: ProPlan.monthly.productID)
        let store = makeStore()
        await store.loadProducts()
        await store.refreshEntitlements()
        let lifetime = try XCTUnwrap(store.lifetime)
        let purchased = await store.purchase(lifetime)
        XCTAssertFalse(purchased)
        XCTAssertEqual(store.activeTier, .monthly)
    }

    @MainActor
    func testCancelRenewalKeepsAccessUntilExpiration() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let transaction = try await session.buyProduct(identifier: ProPlan.monthly.productID)
        let store = makeStore()
        await store.refreshEntitlements()
        let expiration = store.entitlement?.expirationDate

        try session.disableAutoRenewForTransaction(identifier: UInt(transaction.id))
        await store.refreshEntitlements()
        XCTAssertEqual(store.activeTier, .monthly)
        XCTAssertEqual(store.entitlement?.expirationDate, expiration)
    }

    @MainActor
    func testRestoreMonthlyPurchase() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        _ = try await session.buyProduct(identifier: ProPlan.monthly.productID)
        let store = makeStore()
        await store.restore()
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.activeTier, .monthly)
    }

    @MainActor
    func testLifetimePurchase() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        let store = makeStore()
        await store.loadProducts()
        let lifetime = try XCTUnwrap(store.lifetime)
        let purchased = await store.purchase(lifetime)
        XCTAssertTrue(purchased)
        XCTAssertEqual(store.activeTier, .lifetime)
        XCTAssertNil(store.entitlement?.expirationDate)
    }

    @MainActor
    func testPaywallMonthlySnapshot() async throws {
        let session = try makeSession()
        defer { session.clearTransactions() }
        await ProStore.shared.loadProducts()
        await ProStore.shared.refreshEntitlements()
        XCTAssertNotNil(ProStore.shared.monthly)
        XCTAssertNotNil(ProStore.shared.lifetime)
        XCTAssertFalse(ProStore.shared.isPro)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let sizes: [(name: String, size: CGSize)] = [
            ("iPhoneSmall", CGSize(width: 375, height: 667)),
            ("iPhone", CGSize(width: 393, height: 852)),
            ("iPhoneLarge", CGSize(width: 430, height: 932)),
            ("iPhoneLargeText", CGSize(width: 393, height: 852)),
            ("iPhoneDark", CGSize(width: 393, height: 852)),
            ("iPhoneLandscape", CGSize(width: 852, height: 393)),
            ("iPadPortrait", CGSize(width: 768, height: 1024)),
            ("iPadMini", CGSize(width: 744, height: 1133)),
            ("iPadLarge", CGSize(width: 1024, height: 1366)),
            ("iPadLandscape", CGSize(width: 1366, height: 1024)),
            ("iPadSplit", CGSize(width: 507, height: 1024)),
            ("iPadNarrowSplit", CGSize(width: 320, height: 1024))
        ]
        for sample in sizes {
            window.frame = CGRect(origin: .zero, size: sample.size)
            let controller = UIHostingController(rootView:
                PaywallView(onClose: {})
                    .environment(\.dynamicTypeSize, sample.name == "iPhoneLargeText" ? .accessibility1 : .large)
                    .preferredColorScheme(sample.name == "iPhoneDark" ? .dark : .light)
            )
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 500_000_000)
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertGreaterThan(image.size.width, 0)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Paywall-FullScreen-\(sample.name)"
            attachment.lifetime = .keepAlways
            add(attachment)

            if sample.name == "iPhoneLargeText" || sample.name == "iPhoneLandscape" {
                let scrollView = try XCTUnwrap(findScrollView(in: controller.view))
                let bottom = scrollView.contentSize.height - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
                XCTAssertGreaterThan(bottom, 0)
                scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                try await Task.sleep(nanoseconds: 200_000_000)
                let scrolledImage = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let bottomAttachment = XCTAttachment(image: scrolledImage)
                bottomAttachment.name = "Paywall-Scrolled-\(sample.name)"
                bottomAttachment.lifetime = .keepAlways
                add(bottomAttachment)
            }
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}
