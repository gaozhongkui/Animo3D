//
//  PaywallView.swift
//  Animo3D
//
//  Pro Paywall: $2.99 lifetime, unlock all characters/dances + remove watermark + no ads.
//

import SwiftUI

struct PaywallView: View {
    var onClose: () -> Void
    @ObservedObject private var store = ProStore.shared
    @State private var animateItems = false

    private let benefits: [(String, LocalizedStringKey, LocalizedStringKey)] = [
        ("person.2.fill", "Unlock All Characters", "All current and future characters"),
        ("figure.dance", "Unlock All Dances", "Unlimited access to dance library"),
        ("video.fill", "Remove Watermark", "Professional, clean video exports"),
        ("music.note.list", "Unlock All Music", "Full access to high-quality tracks"),
        ("sparkles", "No Ads · Early Access", "Pure experience, priority features"),
    ]

    var body: some View {
        ZStack {
            // Immersive background
            Color(.systemBackground).ignoresSafeArea()

            // Top diffuse gradient
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
                // Close button
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
                                Text("Unlock Livo 3D Pro")
                                    .font(.system(size: 32, weight: .black, design: .rounded))

                                Text("One-time payment · Unlock everything forever")
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

            // Bottom action area
            VStack {
                Spacer()

                VStack(spacing: 12) {
                    if store.isPro {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                            Text("Professional version unlocked")
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
                                Text("\(store.price) Unlock Now")
                                    .font(.system(size: 18, weight: .bold))
                                Text("Lifetime access · No subscription")
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
                            Button("Restore") { }
                            Text("•")
                            Link("Terms", destination: URL(string: "https://example.com")!)
                            Text("•")
                            Link("Privacy", destination: URL(string: "https://example.com")!)
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

    private func benefitRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
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
