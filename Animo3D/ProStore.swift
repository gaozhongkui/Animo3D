//
//  ProStore.swift
//  Animo3D
//
//  In-app purchases (StoreKit 2). Pro unlocks every character, dance and track, and drops the
//  watermark from exported video.
//
//  Sold as an auto-renewable subscription (weekly / monthly / yearly, one group so the tiers can be
//  swapped freely) plus a non-consumable lifetime unlock. Any one of them grants the same thing, so
//  entitlement is "does the user own *any* of our product IDs".
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
        case yearly, monthly, weekly, lifetime
        var productID: String { "com.animar.ar.companion.Animo3D.pro." + rawValue }
    }

    /// Every product that grants Pro. Order is the order the paywall offers them in.
    static let productIDs: [String] = Tier.allCases.map(\.productID)

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
        // Seeded from the cached entitlement so a paying user does not get the watermark back for
        // the moment it takes StoreKit to answer (or for as long as they are offline).
        isPro = UserDefaults.standard.bool(forKey: entitlementKey)
        updatesTask = Self.listenForTransactions()
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    deinit { updatesTask?.cancel() }

    // MARK: - Catalog

    func loadProducts() async {
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

    var subscriptions: [Product] { products.filter { $0.type == .autoRenewable } }
    var lifetime: Product? { products.first { $0.id == Tier.lifetime.productID } }

    /// "3 days free" style line for a product's introductory offer, or nil when it has none.
    func introOfferText(for product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer else { return nil }
        let unit = offer.period.unit
        let n = offer.period.value
        let name: String
        switch unit {
        case .day:   name = n == 1 ? "day" : "days"
        case .week:  name = n == 1 ? "week" : "weeks"
        case .month: name = n == 1 ? "month" : "months"
        case .year:  name = n == 1 ? "year" : "years"
        @unknown default: name = "days"
        }
        switch offer.paymentMode {
        case .freeTrial:  return "\(n) \(name) free"
        case .payAsYouGo: return "\(offer.displayPrice) per \(name)"
        case .payUpFront: return "\(offer.displayPrice) for \(n) \(name)"
        default:          return nil
        }
    }

    /// "week" / "month" / "year", for the "$2.99 / week" line. nil for the lifetime unlock.
    func periodText(for product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
        switch period.unit {
        case .day:   return period.value == 1 ? "day" : "\(period.value) days"
        case .week:  return period.value == 1 ? "week" : "\(period.value) weeks"
        case .month: return period.value == 1 ? "month" : "\(period.value) months"
        case .year:  return period.value == 1 ? "year" : "\(period.value) years"
        @unknown default: return nil
        }
    }

    // MARK: - Buying

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard purchasingID == nil else { return false }
        purchasingID = product.id
        defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard let transaction = try? Self.verify(verification) else {
                    lastError = "That purchase could not be verified."
                    return false
                }
                await transaction.finish()
                await refreshEntitlements()
                return isPro
            case .userCancelled:
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
        if !isPro { lastError = "No previous purchase was found for this Apple ID." }
    }

    // MARK: - Entitlement

    func refreshEntitlements() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verify(result) else { continue }
            guard Self.productIDs.contains(transaction.productID) else { continue }
            if transaction.revocationDate == nil { entitled = true }
        }
        setPro(entitled)
    }

    private func setPro(_ value: Bool) {
        guard value != isPro else { return }
        isPro = value
        UserDefaults.standard.set(value, forKey: entitlementKey)
        NSLog("[ProStore] entitlement -> %@", value ? "PRO" : "free")
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

    // The first N characters/dances are free, the rest need Pro.
    let freeCharacters = 3
    let freeDances = 6
    func characterLocked(_ index: Int) -> Bool { !isPro && index >= freeCharacters }
    func danceLocked(_ index: Int) -> Bool { !isPro && index >= freeDances }
}
