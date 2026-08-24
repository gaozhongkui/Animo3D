//
//  PaywallView.swift
//  Animo3D
//
//  Pro 买断墙：$2.99 永久,解锁全部角色/舞蹈 + 去水印 + 无广告。
//

import SwiftUI

struct PaywallView: View {
    var onClose: () -> Void
    @ObservedObject private var store = ProStore.shared

    private let benefits: [(String, String, String)] = [
        ("person.3.fill", "解锁全部角色", "所有角色随意用,含后续更新"),
        ("figure.dance", "解锁全部舞蹈", "全部动作库无限畅跳"),
        ("drop.fill", "去除水印", "导出视频不带 Animo3D 角标"),
        ("music.note", "全部背景音乐", "内置曲库全部解锁"),
        ("bolt.fill", "无广告 · 抢先体验", "干净无打扰,新功能优先玩"),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // 顶部渐变氛围
            LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93).opacity(0.28), .clear],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        Image(systemName: "crown.fill").font(.system(size: 42)).foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93),
                                                                Color(red: 0.86, green: 0.15, blue: 0.47)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .purple.opacity(0.4), radius: 12, y: 6)
                        Text("Animo3D Pro").font(.title.weight(.bold))
                        Text("一次买断,永久解锁全部内容").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 36)

                    VStack(spacing: 12) {
                        ForEach(benefits, id: \.0) { b in
                            HStack(spacing: 14) {
                                Image(systemName: b.0).font(.body).foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93),
                                                                         Color(red: 0.86, green: 0.15, blue: 0.47)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                                in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.1).font(.subheadline.weight(.semibold))
                                    Text(b.2).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 8)

                    if store.isPro {
                        Label("已解锁 Pro,尽情创作吧", systemImage: "checkmark.seal.fill")
                            .font(.headline).foregroundStyle(.green).padding(.bottom, 8)
                    } else {
                        VStack(spacing: 8) {
                            Button { store.unlock() } label: {   // TODO: StoreKit
                                VStack(spacing: 2) {
                                    Text("\(store.price) 永久解锁").font(.headline)
                                    Text("一次付费 · 永久有效").font(.caption2).opacity(0.9)
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(LinearGradient(colors: [Color(red: 0.49, green: 0.23, blue: 0.93),
                                                                    Color(red: 0.86, green: 0.15, blue: 0.47)],
                                                           startPoint: .leading, endPoint: .trailing),
                                            in: RoundedRectangle(cornerRadius: 16))
                            }
                            Text("非订阅,不会自动续费").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 20)
                }
            }

            Button { onClose() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(Color(.secondarySystemBackground), in: Circle())
            }.padding(16)
        }
    }
}
