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
    @State private var animateItems = false

    private let benefits: [(String, String, String)] = [
        ("person.2.fill", "解锁全部角色", "所有内置及未来新增角色"),
        ("figure.dance", "解锁全部舞蹈", "海量动作库无限畅享"),
        ("video.fill", "去除导出水印", "让创作更纯净、更专业"),
        ("music.note.list", "解锁全部音乐", "内置高清音乐库随心用"),
        ("sparkles", "无广告 · 抢先体验", "极致纯净,新功能优先体验"),
    ]

    var body: some View {
        ZStack {
            // 沉浸式背景
            Color(.systemBackground).ignoresSafeArea()

            // 顶部弥散渐变
            ZStack {
                Circle()
                    .fill(Color(rgb: 0x6366F1).opacity(0.15))
                    .frame(width: 400, height: 400)
                    .blur(radius: 60)
                    .offset(x: -150, y: -200)

                Circle()
                    .fill(Color(rgb: 0xA855F7).opacity(0.15))
                    .frame(width: 400, height: 400)
                    .blur(radius: 60)
                    .offset(x: 150, y: -250)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 关闭按钮
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(20)
                }

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 32) {
                        // Header
                        VStack(spacing: 16) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 100, height: 100)
                                    .shadow(color: Color(rgb: 0x6366F1).opacity(0.3), radius: 20, y: 10)

                                Image(systemName: "crown.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.white)
                            }

                            VStack(spacing: 8) {
                                Text("解锁 Animo3D Pro")
                                    .font(.system(size: 32, weight: .black, design: .rounded))

                                Text("一次付费 · 永久解锁全部功能")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 10)

                        // Benefits List
                        VStack(spacing: 14) {
                            ForEach(0..<benefits.count, id: \.self) { i in
                                let b = benefits[i]
                                benefitRow(icon: b.0, title: b.1, subtitle: b.2)
                                    .offset(y: animateItems ? 0 : 20)
                                    .opacity(animateItems ? 1 : 0)
                                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.1), value: animateItems)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 120)
                }
            }

            // 底部操作区
            VStack {
                Spacer()

                VStack(spacing: 12) {
                    if store.isPro {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("已成功解锁专业版")
                        }
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(rgb: 0x6366F1))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    } else {
                        Button {
                            withAnimation { store.unlock() }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(store.price) 立即解锁")
                                    .font(.system(size: 18, weight: .bold))
                                Text("终身会员 · 无需订阅")
                                    .font(.system(size: 11, weight: .medium))
                                    .opacity(0.8)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                            .background(
                                LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)], startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .shadow(color: Color(rgb: 0x6366F1).opacity(0.4), radius: 15, y: 8)
                        }

                        HStack(spacing: 20) {
                            Button("恢复购买") { }
                            Text("•")
                            Link("服务条款", destination: URL(string: "https://example.com")!)
                            Text("•")
                            Link("隐私政策", destination: URL(string: "https://example.com")!)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .padding(.top, 24)
                .background(
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .top, endPoint: .bottom))
                        .ignoresSafeArea()
                )
            }
        }
        .onAppear {
            animateItems = true
        }
    }

    private func benefitRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color(rgb: 0x6366F1))
                .frame(width: 44, height: 44)
                .background(Color(rgb: 0x6366F1).opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(rgb: 0x6366F1).opacity(0.2))
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color(.label).opacity(0.03), lineWidth: 1)
        )
    }
}

#Preview {
    PaywallView(onClose: {})
}
