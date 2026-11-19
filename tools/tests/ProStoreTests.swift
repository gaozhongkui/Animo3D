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

    private var accessFixture: ProContentAccess {
        ProContentAccess(
            characterIDs: ["my_character"] + (1...8).map { "character_\($0)" },
            danceIDs: (1...12).map { "dance_\($0)" },
            importedCharacterIDs: ["my_character"],
            builtInCharacterID: "character_8",
            builtInDanceID: "dance_12"
        )
    }

    func testFreeLibraryHasExactlyThreeCharactersAndSixDances() {
        let access = accessFixture
        XCTAssertEqual(access.freeCharacterIDs.count, 3)
        XCTAssertEqual(access.freeDanceIDs.count, 6)
        XCTAssertEqual((1...8).filter { access.canUseCharacter("character_\($0)", isPro: false) }.count, 3)
        XCTAssertEqual((1...12).filter { access.canUseDance("dance_\($0)", isPro: false) }.count, 6)
    }

    func testBundledContentRemainsFreeWithinTheQuota() {
        let access = accessFixture
        XCTAssertTrue(access.canUseCharacter("character_8", isPro: false))
        XCTAssertTrue(access.canUseDance("dance_12", isPro: false))
    }

    func testImportedCharactersDoNotConsumeFreeCatalogSlots() {
        let catalog = (1...8).map { "character_\($0)" }
        let original = ProContentAccess(characterIDs: catalog, danceIDs: [])
        let imported = ProContentAccess(
            characterIDs: ["mine_a", "mine_b"] + catalog,
            danceIDs: [],
            importedCharacterIDs: ["mine_a", "mine_b"]
        )
        XCTAssertEqual(original.freeCharacterIDs, imported.freeCharacterIDs)
        XCTAssertTrue(imported.canUseCharacter("mine_a", isPro: false))
        XCTAssertTrue(imported.canUseCharacter("mine_b", isPro: false))
        XCTAssertFalse(imported.canUseCharacter("character_4", isPro: false))
    }

    func testFilteringOrReorderingTheVisibleListDoesNotUnlockPaidDances() {
        let access = accessFixture
        let category = ["dance_7", "dance_9", "dance_12"]
        XCTAssertFalse(access.canUseDance(category[0], isPro: false))
        XCTAssertFalse(access.canUseDance(category[1], isPro: false))
        XCTAssertTrue(access.canUseDance(category[2], isPro: false))
    }

    func testProUnlocksTheEntireKnownCatalogAndFreeAccessReturnsAfterExpiration() {
        let access = accessFixture
        for id in (1...8).map({ "character_\($0)" }) {
            XCTAssertTrue(access.canUseCharacter(id, isPro: true))
        }
        for id in (1...12).map({ "dance_\($0)" }) {
            XCTAssertTrue(access.canUseDance(id, isPro: true))
        }
        XCTAssertFalse(access.canUseCharacter("character_4", isPro: false))
        XCTAssertFalse(access.canUseDance("dance_7", isPro: false))
    }

    func testInvalidAndDuplicateCatalogIDsDoNotGrantExtraFreeSlots() {
        let access = ProContentAccess(
            characterIDs: ["", "a", "a", "b", "c", "d"],
            danceIDs: ["x", "x"],
            builtInCharacterID: "missing"
        )
        XCTAssertEqual(access.freeCharacterIDs, ["a", "b", "c"])
        XCTAssertEqual(access.freeDanceIDs, ["x"])
        XCTAssertFalse(access.canUseCharacter("missing", isPro: true))
        XCTAssertFalse(access.canUseDance("missing", isPro: true))
        XCTAssertFalse(access.canUseCharacter("", isPro: true))
        XCTAssertFalse(access.canUseDance("", isPro: true))
    }

    @MainActor
    private func assertPaidLibraryAccess(
        _ allowed: Bool,
        in store: ProStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(store.characterLocked("character_4", in: accessFixture), !allowed, file: file, line: line)
        XCTAssertEqual(store.danceLocked("dance_7", in: accessFixture), !allowed, file: file, line: line)
        XCTAssertFalse(store.characterLocked("my_character", in: accessFixture), file: file, line: line)
        XCTAssertFalse(store.characterLocked("character_1", in: accessFixture), file: file, line: line)
        XCTAssertFalse(store.danceLocked("dance_1", in: accessFixture), file: file, line: line)
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
        assertPaidLibraryAccess(true, in: store)
        XCTAssertNotNil(store.entitlement?.expirationDate)

        try session.expireSubscription(productIdentifier: ProPlan.monthly.productID)
        await waitForTier(nil, in: store, refresh: true)
        XCTAssertFalse(store.isPro)
        assertPaidLibraryAccess(false, in: store)
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
        assertPaidLibraryAccess(true, in: store)
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
        assertPaidLibraryAccess(false, in: store)
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
        assertPaidLibraryAccess(true, in: store)
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
        assertPaidLibraryAccess(true, in: store)
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
        assertPaidLibraryAccess(true, in: store)
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
