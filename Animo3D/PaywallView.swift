//
//  PaywallView.swift
//  Animo3D
//
//  订阅墙（UI）。真实内购需接入 StoreKit + App Store Connect 商品，这里先做界面。
//

import SwiftUI

struct PaywallView: View {
    var onClose: () -> Void
    @State private var plan = 1   // 0=月 1=年

    private let benefits = [
        ("figure.dance", "全部角色与舞蹈", "解锁所有角色、动作与后续更新"),
        ("music.note", "全部背景音乐", "内置曲库无限使用"),
        ("sparkles", "无水印 · 高清导出", "作品更清晰,分享更专业"),
        ("bolt.fill", "抢先体验新功能", "视频驱动等 Beta 功能优先开放"),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(systemName: "crown.fill").font(.system(size: 44))
                            .foregroundStyle(.white)
                            .frame(width: 88, height: 88)
                            .background(LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93),
                                                                Color(red: 0.86, green: 0.15, blue: 0.47)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        Text("升级 Animo3D Pro").font(.title2.weight(.bold))
                        Text("解锁全部内容,创作更自由").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    VStack(spacing: 14) {
                        ForEach(benefits, id: \.0) { b in
                            HStack(spacing: 14) {
                                Image(systemName: b.0).font(.body).foregroundStyle(.tint)
                                    .frame(width: 34, height: 34)
                                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.1).font(.subheadline.weight(.medium))
                                    Text(b.2).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    VStack(spacing: 10) {
                        planCard(index: 1, title: "年度", price: "¥168 / 年", note: "低至 ¥14/月 · 最超值", best: true)
                        planCard(index: 0, title: "月度", price: "¥28 / 月", note: "灵活订阅", best: false)
                    }
                    .padding(.horizontal, 20)

                    Button { onClose() } label: {
                        Text("订阅").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.horizontal, 20)

                    Text("订阅将自动续费,可随时在设置中取消。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 30)
                }
            }

            Button { onClose() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color(.secondarySystemBackground), in: Circle())
            }
            .padding(16)
        }
    }

    private func planCard(index: Int, title: String, price: String, note: String, best: Bool) -> some View {
        Button { plan = index } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(.subheadline.weight(.semibold))
                        if best {
                            Text("推荐").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                        }
                    }
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(price).font(.subheadline.weight(.medium))
                Image(systemName: plan == index ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(plan == index ? Color.accentColor : Color.secondary)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor, lineWidth: plan == index ? 2 : 0))
        }
        .buttonStyle(.plain)
    }
}
