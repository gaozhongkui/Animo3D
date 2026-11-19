import Foundation

nonisolated enum ProPlan: String, CaseIterable, Codable {
    case monthly
    case lifetime

    var productID: String {
        switch self {
        case .monthly: return "com.animar.ar.companion.animo3d.monthly"
        case .lifetime: return "com.animar.ar.companion.animo.lifetime"
        }
    }
}

nonisolated struct ProEntitlement: Codable, Equatable {
    let plan: ProPlan
    /// Includes an App Store billing grace period when one is verified.
    let expirationDate: Date?

    func isActive(at date: Date = Date()) -> Bool {
        switch plan {
        case .lifetime: return true
        case .monthly: return expirationDate.map { $0 > date } ?? false
        }
    }

    static func cached(
        data: Data?,
        legacyIsPro: Bool,
        at date: Date = Date()
    ) -> ProEntitlement? {
        if let data {
            guard let entitlement = try? JSONDecoder().decode(Self.self, from: data),
                  entitlement.isActive(at: date) else { return nil }
            return entitlement
        }
        // Before monthly subscriptions existed, this flag could only mean lifetime access.
        return legacyIsPro ? ProEntitlement(plan: .lifetime, expirationDate: nil) : nil
    }
}
