//
//  PaywallView.swift
//  Animo3D
//
//  会员 & 钻石 商店。会员：月/年/永久买断；钻石：消耗币，每次生成扣 100 钻。
//  真实付款需接 StoreKit，这里购买按钮先走本地经济（演示用）。
//

import SwiftUI

struct PaywallView: View {
    var onClose: () -> Void
    @ObservedObject private var store = DiamondStore.shared
    @State private var plan = "lifetime"

    private let benefits = [
        ("figure.dance", "全部角色与舞蹈"),
        ("music.note", "全部背景音乐"),
        ("sparkles", "无水印 · 高清导出"),
        ("bolt.fill", "抢先体验新功能"),
    ]

    // 会员方案
    private let plans: [(id: String, title: String, price: String, note: String, best: Bool)] = [
        ("lifetime", "永久买断", "$99", "一次付费,永久使用 · 最超值", true),
        ("yearly",   "年度",     "$29.99 / 年", "低至 $2.5/月", false),
        ("monthly",  "月度",     "$4.99 / 月", "灵活订阅", false),
    ]
    // 钻石包（含赠送）
    private let packs: [(amount: Int, bonus: Int, price: String)] = [
        (100, 0, "$0.99"), (500, 50, "$3.99"), (1200, 200, "$8.99"), (3000, 800, "$19.99"),
    ]
    private let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 22) {
                    header

                    // 会员
                    group("会员 Pro") {
                        ForEach(plans, id: \.id) { p in planRow(p) }
                        Button { buyPlan() } label: {
                            Text(store.isPro ? "已是会员" : "开通会员")
                                .font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(store.isPro ? Color.gray : Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        }.disabled(store.isPro).padding(.top, 4)
                    }

                    // 钻石
                    group("钻石 · 每次生成消耗 \(GenerationCost.perGenerate) 钻") {
                        LazyVGrid(columns: cols, spacing: 12) {
                            ForEach(packs, id: \.amount) { pk in diamondPack(pk) }
                        }
                    }

                    Text("会员为自动续费(永久除外),可随时在设置取消。钻石为消耗型,购买后不退。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 30)
                }
                .padding(.top, 8)
            }

            Button { onClose() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color(.secondarySystemBackground), in: Circle())
            }.padding(16)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill").font(.system(size: 40)).foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93),
                                                    Color(red: 0.86, green: 0.15, blue: 0.47)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(store.isPro ? "你已是 Pro 会员" : "升级 Animo3D Pro").font(.title2.weight(.bold))
            // 钻石余额
            HStack(spacing: 6) {
                Image(systemName: "diamond.fill").foregroundStyle(.cyan)
                Text("\(store.balance)").font(.headline.monospacedDigit())
                Text("钻石").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())

            HStack(spacing: 14) {
                ForEach(benefits, id: \.0) { b in
                    VStack(spacing: 6) {
                        Image(systemName: b.0).font(.body).foregroundStyle(.tint)
                        Text(b.1).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(width: 70)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.top, 20).padding(.horizontal, 16)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).padding(.horizontal, 20)
            VStack(spacing: 12) { content() }.padding(.horizontal, 20)
        }
    }

    private func planRow(_ p: (id: String, title: String, price: String, note: String, best: Bool)) -> some View {
        Button { plan = p.id } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.title).font(.subheadline.weight(.semibold))
                        if p.best {
                            Text("最超值").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.pink, in: Capsule())
                        }
                    }
                    Text(p.note).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(p.price).font(.subheadline.weight(.semibold))
                Image(systemName: plan == p.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(plan == p.id ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: plan == p.id ? 2 : 0))
        }.buttonStyle(.plain)
    }

    private func diamondPack(_ pk: (amount: Int, bonus: Int, price: String)) -> some View {
        Button { store.addDiamonds(pk.amount + pk.bonus) } label: {
            VStack(spacing: 6) {
                Image(systemName: "diamond.fill").font(.title2).foregroundStyle(.cyan)
                Text("\(pk.amount)").font(.headline.monospacedDigit())
                if pk.bonus > 0 {
                    Text("+\(pk.bonus) 赠").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text(" ").font(.caption2)
                }
                Text(pk.price).font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    private func buyPlan() {
        // TODO: 接 StoreKit 真实购买；当前本地激活(演示)
        store.activatePro(kind: plan, bonusDiamonds: plan == "lifetime" ? 1000 : 0)
    }
}
