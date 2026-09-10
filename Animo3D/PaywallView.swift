//
//  PaywallView.swift
//  Animo3D
//
//  Pro Paywall: Simplified for a single Lifetime Unlock.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    var onClose: () -> Void
    /// Where the user came from. The same screen shown after tapping a locked character and shown
    /// from the profile button convert very differently, and without this they are one number.
    var source: String = "unknown"
    @ObservedObject private var store = ProStore.shared
    @State private var animateItems = false

    private var lifetimeProduct: Product? {
        store.products.first { $0.id == ProStore.Tier.lifetime.productID }
    }

    private let benefits: [(String, LocalizedStringKey, LocalizedStringKey)] = [
        ("person.2.fill", "Unlock All Characters", "Access to all current and future 3D models"),
        ("figure.dance", "Unlimited Animations", "No restrictions on dance library"),
        ("video.fill", "No Watermark", "Professional, clean video exports"),
        ("sparkles", "Pro Features", "High-priority updates and ad-free experience"),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // Background glow
            ZStack {
                Circle().fill(Color(rgb: 0x6366F1).opacity(0.12)).frame(width: 400).blur(radius: 60).offset(x: -150, y: -250)
                Circle().fill(Color(rgb: 0xA855F7).opacity(0.12)).frame(width: 400).blur(radius: 60).offset(x: 150, y: -300)
            }.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.secondary)
                            .padding(10).background(.ultraThinMaterial, in: Circle())
                    }
                }.padding(20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 40) {
                        // Icon & Title
                        VStack(spacing: 20) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 100, height: 100)
                                    .shadow(color: Color(rgb: 0x6366F1).opacity(0.3), radius: 20, y: 10)
                                Image(systemName: "crown.fill").font(.system(size: 48)).foregroundStyle(.white)
                            }

                            VStack(spacing: 8) {
                                Text("Livo 3D Pro").font(.system(size: 36, weight: .black, design: .rounded))
                                Text("Lifetime Access").font(.title3.bold()).foregroundStyle(Color(rgb: 0x6366F1))
                            }
                        }

                        // Benefits
                        VStack(spacing: 16) {
                            ForEach(0..<benefits.count, id: \.self) { i in
                                let b = benefits[i]
                                benefitRow(icon: b.0, title: b.1, subtitle: b.2)
                                    .offset(y: animateItems ? 0 : 20).opacity(animateItems ? 1 : 0)
                                    .animation(.spring(response: 0.5).delay(Double(i) * 0.1), value: animateItems)
                            }
                        }.padding(.horizontal, 24)

                        // Price, but only for someone who could still buy. An owner was being
                        // shown a price - or, when StoreKit had nothing to offer, an "App Store
                        // unavailable" error - for a thing they already own; and with the price
                        // block gone the line landed under the bottom bar's translucent scrim and
                        // showed through the button.
                        if !store.isPro {
                            if let product = lifetimeProduct {
                                VStack(spacing: 4) {
                                    Text(product.displayPrice)
                                        .font(.system(size: 28, weight: .black, design: .rounded))
                                    Text("One-time payment · Forever yours")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                }
                                .padding(.top, 10)
                            } else if store.loadFailed {
                                Text("App Store unavailable").foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                        }
                    }
                    .padding(.bottom, 160)
                }
            }

            // Bottom CTA
            VStack {
                Spacer()
                purchaseArea
                    .padding(.horizontal, 24).padding(.bottom, 20).padding(.top, 30)
                    .background(
                        Rectangle().fill(.ultraThinMaterial)
                            .mask(LinearGradient(colors: [.clear, .white, .white], startPoint: .top, endPoint: .bottom))
                            .ignoresSafeArea()
                    )
            }
        }
        .onAppear {
            animateItems = true
            Track.log(.paywallShown, ["source": source])
        }
    }

    private var purchaseArea: some View {
        VStack(spacing: 16) {
            // One button in both states rather than a button swapped for a label. An owner who
            // opens this screen should see the thing they would have tapped, greyed out and inert -
            // that reads as "already yours". Replacing it with a differently shaped badge left
            // people looking for the button, and the gradient CTA sitting next to a purple
            // "unlocked" notice looked like it was still selling something.
            Button {
                guard !store.isPro, let p = lifetimeProduct else { return }
                Task { await store.purchase(p) }
            } label: {
                ZStack {
                    if store.purchasingID != nil {
                        ProgressView().tint(.white)
                    } else if store.isPro {
                        Label("Pro Version Unlocked", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                    } else {
                        Text("Unlock Everything Forever").font(.headline)
                    }
                }
                .foregroundStyle(store.isPro ? Color.secondary : Color.white)
                .frame(maxWidth: .infinity).frame(height: 60)
                .background(store.isPro
                            ? AnyShapeStyle(Color(.tertiarySystemFill))
                            : AnyShapeStyle(LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)],
                                                           startPoint: .leading, endPoint: .trailing)))
                .clipShape(Capsule())
                // No glow on the grey state: a shadow is what makes a control look pressable.
                .shadow(color: store.isPro ? .clear : Color(rgb: 0x6366F1).opacity(0.4), radius: 15, y: 8)
            }
            .disabled(store.isPro || lifetimeProduct == nil || store.purchasingID != nil)

            // Terms and Privacy stay reachable in both states - App Store review expects them on
            // the purchase screen whether or not this particular user has bought yet. Restore is
            // the only part that goes: there is nothing left to restore.
            HStack(spacing: 20) {
                if !store.isPro {
                    Button("Restore") { Task { await store.restore() } }.disabled(store.isRestoring)
                    Text("•")
                }
                Link("Terms", destination: URL(string: "https://sites.google.com/view/livo3dtermsofservice")!)
                Text("•")
                Link("Privacy", destination: URL(string: "https://sites.google.com/view/livo3dprivacypolicy")!)
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func benefitRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon).font(.headline).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(Color(rgb: 0x6366F1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
