import Foundation
import Combine
import StoreKit

/// StoreKit 2: monthly auto-renewing Pro and the existing non-consumable lifetime unlock.
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    typealias Tier = ProPlan

    static let productIDs = Tier.allCases.map(\.productID)

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement: ProEntitlement?
    @Published private(set) var purchasingID: String?
    @Published private(set) var isRestoring = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var loadFailed = false
    @Published var lastError: String?

    var isPro: Bool { entitlement?.isActive() == true }
    var activeTier: Tier? { isPro ? entitlement?.plan : nil }
    var monthly: Product? { product(for: .monthly) }
    var lifetime: Product? { product(for: .lifetime) }

    private static let entitlementKey = "pro_entitlement"
    private static let legacyEntitlementKey = "pro_no_watermark"
    private let defaults: UserDefaults
    private var updatesTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(defaults: UserDefaults = .standard, startsAutomatically: Bool = true) {
        self.defaults = defaults
        entitlement = ProEntitlement.cached(
            data: defaults.data(forKey: Self.entitlementKey),
            legacyIsPro: defaults.bool(forKey: Self.legacyEntitlementKey)
        )
        listenForTransactions()
        scheduleExpirationRefresh()
        guard startsAutomatically else { return }
        Task { [weak self] in
            await self?.loadProducts()
            await self?.refreshEntitlements()
        }
    }

    deinit {
        updatesTask?.cancel()
        expirationTask?.cancel()
    }

    // MARK: - Catalog

    func product(for tier: Tier) -> Product? {
        products.first { $0.id == tier.productID }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        loadFailed = false
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            products = Self.productIDs.compactMap { id in fetched.first { $0.id == id } }
            loadFailed = products.count != Self.productIDs.count
        } catch {
            loadFailed = true
            NSLog("[ProStore] product load failed: %@", error.localizedDescription)
        }
    }

    // MARK: - Buying and restoring

    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        guard !isPro, purchasingID == nil, !isRestoring,
              Self.productIDs.contains(product.id) else { return false }
        purchasingID = product.id
        lastError = nil
        defer { purchasingID = nil }
        Track.log(.purchaseStarted, ["product": product.id])
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try Self.verify(verification)
                await transaction.finish()
                await refreshEntitlements()
                Track.log(.purchaseSucceeded, ["product": product.id])
                return isPro
            case .userCancelled:
                Track.log(.purchaseFailed, ["product": product.id, "reason": "cancelled"])
                return false
            case .pending:
                lastError = "Your purchase is pending approval."
                return false
            @unknown default:
                return false
            }
        } catch {
            lastError = error.localizedDescription
            Track.log(.purchaseFailed, ["product": product.id, "reason": "error"])
            return false
        }
    }

    func restore() async {
        guard !isRestoring, purchasingID == nil else { return }
        isRestoring = true
        lastError = nil
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            Track.log(.purchaseRestored, ["ok": isPro ? "yes" : "no"])
            if !isPro { lastError = "No active purchase was found for this Apple ID." }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Entitlements

    func refreshEntitlements() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        var current: ProEntitlement?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? Self.verify(result),
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else { continue }

            if transaction.productID == Tier.lifetime.productID {
                current = ProEntitlement(plan: .lifetime, expirationDate: nil)
                break
            }
            if transaction.productID == Tier.monthly.productID,
               let expiration = await monthlyExpiration(for: transaction) {
                current = ProEntitlement(plan: .monthly, expirationDate: expiration)
            }
        }
        guard generation == refreshGeneration else { return }
        entitlement = current
        // An explicit inactive value prevents an expired month from falling back to the old
        // Boolean flag and accidentally becoming lifetime access on the next launch.
        let cache = current ?? ProEntitlement(plan: .monthly, expirationDate: nil)
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Self.entitlementKey)
        }
        defaults.set(current?.plan == .lifetime, forKey: Self.legacyEntitlementKey)
        Track.setPro(isPro)
        scheduleExpirationRefresh()
    }

    private func monthlyExpiration(for transaction: Transaction) async -> Date? {
        if let expiration = transaction.expirationDate, expiration > Date() { return expiration }
        guard let groupID = transaction.subscriptionGroupID,
              let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else { return nil }
        for status in statuses where status.state == .inGracePeriod {
            guard let renewal = try? Self.verify(status.renewalInfo),
                  let renewalTransaction = try? Self.verify(status.transaction),
                  renewalTransaction.productID == Tier.monthly.productID,
                  renewalTransaction.revocationDate == nil,
                  let expiration = renewal.gracePeriodExpirationDate,
                  expiration > Date() else { continue }
            return expiration
        }
        return nil
    }

    private func listenForTransactions() {
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let transaction = try? Self.verify(update),
                      Self.productIDs.contains(transaction.productID) else { continue }
                await transaction.finish()
                await self?.refreshEntitlements()
            }
        }
    }

    private func scheduleExpirationRefresh() {
        expirationTask?.cancel()
        guard let expiration = entitlement?.expirationDate, isPro else { return }
        let delay = max(0, expiration.timeIntervalSinceNow)
        expirationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            await self?.refreshEntitlements()
        }
    }

    private nonisolated static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }

    let freeCharacters = 3
    let freeDances = 6
    func characterLocked(_ index: Int) -> Bool { !isPro && index >= freeCharacters }
    func danceLocked(_ index: Int) -> Bool { !isPro && index >= freeDances }
}
