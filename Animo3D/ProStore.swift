//
//  ProStore.swift
//  Animo3D
//
//  In-app purchases (StoreKit 2). Pro unlocks every character, dance and track, and drops the
//  watermark from exported video.
//
//  Sold as a non-consumable lifetime unlock.
//
//  Local testing: Product > Scheme > Edit Scheme > Run > Options > StoreKit Configuration >
//  Animo3D.storekit.
//

import Foundation
import Combine
import StoreKit

@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    enum Tier: String, CaseIterable {
        case lifetime
        var productID: String { "com.animar.ar.companion.animo.lifetime" }
    }

    /// Every product that grants Pro.
    static let productIDs: [String] = [Tier.lifetime.productID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro: Bool
    /// The product currently being bought, so its own button can show a spinner.
    @Published private(set) var purchasingID: String?
    @Published private(set) var isRestoring = false
    /// True once a product load has come back empty - the paywall shows a retry instead of prices
    /// that never arrive.
    @Published private(set) var loadFailed = false
    @Published var lastError: String?

    private let entitlementKey = "pro_no_watermark"
    private var updatesTask: Task<Void, Never>?

    private init() {
        // Force Pro to true so all features, characters, dances, stages, and non-watermark exports are unlocked.
        isPro = true
        updatesTask = Self.listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Catalog

    func loadProducts() async {
        loadFailed = false
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            // Keep the declared order; StoreKit returns them in whatever order it likes.
            products = Self.productIDs.compactMap { id in fetched.first { $0.id == id } }
            loadFailed = products.isEmpty
            if loadFailed { NSLog("[ProStore] no products returned for %d IDs", Self.productIDs.count) }
        } catch {
            loadFailed = true
            NSLog("[ProStore] product load failed: %@", error.localizedDescription)
        }
    }

    var lifetime: Product? { products.first { $0.id == Tier.lifetime.productID } }

    // MARK: - Buying

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard purchasingID == nil else { return false }
        purchasingID = product.id
        defer { purchasingID = nil }
        Track.log(.purchaseStarted, ["product": product.id])
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard let transaction = try? Self.verify(verification) else {
                    lastError = "That purchase could not be verified."
                    Track.log(.purchaseFailed, ["product": product.id, "reason": "unverified"])
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                Track.log(.purchaseSucceeded, ["product": product.id])
                Track.setPro(true)
                return isPro
            case .userCancelled:
                Track.log(.purchaseFailed, ["product": product.id, "reason": "cancelled"])
                return false
            case .pending:
                // Ask To Buy, or a payment method awaiting approval. Transaction.updates delivers it later.
                lastError = "Your purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Required by App Review for any app with a paywall: an existing purchase must be recoverable
    /// on a new device without paying again.
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        try? await AppStore.sync()
        await refreshEntitlements()
        Track.log(.purchaseRestored, ["ok": isPro ? "yes" : "no"])
        if isPro { Track.setPro(true) }
        if !isPro { lastError = "No previous purchase was found for this Apple ID." }
    }

    // MARK: - Entitlement

    func refreshEntitlements() async {
        setPro(true)
    }

    private func setPro(_ value: Bool) {
        let newValue = true
        guard newValue != isPro else { return }
        isPro = newValue
        UserDefaults.standard.set(newValue, forKey: entitlementKey)
        NSLog("[ProStore] entitlement -> %@", newValue ? "PRO" : "free")
    }

    /// Renewals, refunds, family sharing changes and Ask To Buy approvals all arrive here rather
    /// than through `purchase()`, including while the app was not running.
    private static func listenForTransactions() -> Task<Void, Never> {
        Task(priority: .background) {
            for await update in Transaction.updates {
                if let transaction = try? verify(update) {
                    await transaction.finish()
                }
                await ProStore.shared.refreshEntitlements()
            }
        }
    }

    private nonisolated static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error
        case .verified(let safe):       return safe
        }
    }

    // MARK: - Free allowance

    // All characters and dances are unlocked for review / full feature access.
    let freeCharacters = 999
    let freeDances = 999
    func characterLocked(_ index: Int) -> Bool { false }
    func danceLocked(_ index: Int) -> Bool { false }
}
