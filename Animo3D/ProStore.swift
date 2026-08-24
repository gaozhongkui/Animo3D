//
//  ProStore.swift
//  Animo3D
//
//  极简变现：一次性永久买断 $2.99，唯一权益=去掉视频右下角水印。
//  免费用户导出的视频带 "Animo3D" 水印（也是免费传播）。真实付款接 StoreKit,这里先本地。
//

import Foundation
import Combine

final class ProStore: ObservableObject {
    static let shared = ProStore()
    @Published private(set) var isPro: Bool
    private let key = "pro_no_watermark"

    private init() { isPro = UserDefaults.standard.bool(forKey: key) }

    /// 解锁 Pro（TODO: 接 StoreKit 真实购买后调用）。
    func unlock() {
        isPro = true
        UserDefaults.standard.set(true, forKey: key)
    }

    let price = "$2.99"

    // 免费额度：前 N 个角色/舞蹈免费，其余 Pro 解锁
    let freeCharacters = 3
    let freeDances = 6
    func characterLocked(_ index: Int) -> Bool { !isPro && index >= freeCharacters }
    func danceLocked(_ index: Int) -> Bool { !isPro && index >= freeDances }
}
