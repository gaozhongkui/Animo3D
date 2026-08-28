//
//  ProStore.swift
//  Animo3D
//
//  Minimal monetization: a one-time $2.99 lifetime purchase whose only benefit is removing the watermark in the video's bottom-right corner.
//  Videos exported by free users carry the "Animo3D" watermark (which doubles as free promotion). Real payments will go through StoreKit; this is local for now.
//

import Foundation
import Combine

final class ProStore: ObservableObject {
    static let shared = ProStore()
    @Published private(set) var isPro: Bool
    private let key = "pro_no_watermark"

    private init() { isPro = UserDefaults.standard.bool(forKey: key) }

    /// Unlocks Pro (TODO: call this after wiring up the real StoreKit purchase).
    func unlock() {
        isPro = true
        UserDefaults.standard.set(true, forKey: key)
    }

    let price = "$2.99"

    // Free allowance: the first N characters/dances are free, the rest need Pro
    let freeCharacters = 3
    let freeDances = 6
    func characterLocked(_ index: Int) -> Bool { !isPro && index >= freeCharacters }
    func danceLocked(_ index: Int) -> Bool { !isPro && index >= freeDances }
}
