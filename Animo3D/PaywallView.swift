//
//  PaywallView.swift
//  Animo3D
//
//  Pro Paywall: Monthly subscription or lifetime unlock.
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
    @State private var selectedTier = ProStore.Tier.monthly
    @State private var showManageSubscriptions = false

    private var selectedProduct: Product? { store.product(for: selectedTier) }
    private var isBusy: Bool { store.purchasingID != nil || store.isRestoring }

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
                    VStack(spacing: 20) {
                        // Icon & Title
                        VStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 72, height: 72)
                                    .shadow(color: Color(rgb: 0x6366F1).opacity(0.3), radius: 16, y: 8)
                                Image(systemName: "crown.fill").font(.system(size: 34)).foregroundStyle(.white)
                            }

                            VStack(spacing: 6) {
                                Text("Livo 3D Pro").font(.system(size: 30, weight: .black, design: .rounded))
                                Text(LocalizedStringKey(store.isPro ? "Pro Version Unlocked" : "Choose your Pro plan"))
                                    .font(.headline)
                                    .foregroundStyle(Color(rgb: 0x6366F1))
                            }
                        }

                        if !store.isPro {
                            VStack(spacing: 12) {
                                planCard(.monthly)
                                planCard(.lifetime)
                            }
                            .padding(.horizontal, 24)
                        }

                        VStack(spacing: 12) {
                            ForEach(0..<benefits.count, id: \.self) { i in
                                let benefit = benefits[i]
                                benefitRow(icon: benefit.0, title: benefit.1, subtitle: benefit.2)
                                    .offset(y: animateItems ? 0 : 20)
                                    .opacity(animateItems ? 1 : 0)
                                    .animation(.spring(response: 0.5).delay(Double(i) * 0.1), value: animateItems)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 550)
            .frame(maxWidth: .infinity)

        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseArea
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .frame(maxWidth: 550)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
        .onAppear {
            animateItems = true
            Track.log(.paywallShown, ["source": source])
        }
        .task {
            if store.products.isEmpty { await store.loadProducts() }
            await store.refreshEntitlements()
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .alert("Purchase unavailable", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(L(store.lastError ?? ""))
        }
        .trackScreen("Paywall")
    }

    private func planCard(_ tier: ProStore.Tier) -> some View {
        let selected = selectedTier == tier
        let product = store.product(for: tier)
        return Button {
            selectedTier = tier
            HapticManager.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color(rgb: 0x6366F1) : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(tier == .monthly ? "Monthly Subscription" : "Lifetime Access"))
                        .font(.headline)
                    Text(LocalizedStringKey(
                        tier == .monthly ? "Renews monthly · Cancel anytime" : "One-time payment · Forever yours"
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let product {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice).font(.title3.bold())
                        if tier == .monthly {
                            Text("per month").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if store.isLoadingProducts {
                    ProgressView()
                } else {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color(rgb: 0x6366F1) : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var purchaseArea: some View {
        VStack(spacing: 14) {
            if let tier = store.activeTier {
                Text(LocalizedStringKey(tier == .monthly ? "Monthly Subscription Active" : "Lifetime Access"))
                    .font(.headline)
                if tier == .monthly, let expiration = store.entitlement?.expirationDate {
                    Text("Access through \(expiration.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let product = selectedProduct {
                Group {
                    if selectedTier == .monthly {
                        Text("\(product.displayPrice) / month")
                    } else {
                        Text(product.displayPrice)
                    }
                }
                .font(.system(size: 28, weight: .black, design: .rounded))
            } else if store.isLoadingProducts {
                ProgressView()
            }

            if !store.isPro, store.loadFailed {
                Button {
                    Task { await store.loadProducts() }
                } label: {
                    Label("App Store unavailable · Tap to Retry", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .disabled(store.isLoadingProducts || isBusy)
            }

            Button {
                guard !store.isPro, let product = selectedProduct else { return }
                Task { await store.purchase(product) }
            } label: {
                ZStack {
                    if store.purchasingID != nil {
                        ProgressView().tint(.white)
                    } else if store.isPro {
                        Label("Pro Version Unlocked", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                    } else {
                        Text(LocalizedStringKey(
                            selectedTier == .monthly ? "Subscribe Monthly" : "Unlock Everything Forever"
                        ))
                        .font(.headline)
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
            .disabled(store.isPro || selectedProduct == nil || isBusy)

            if !store.isPro, selectedTier == .monthly {
                Text("Monthly subscription renews automatically until canceled. Manage or cancel in App Store settings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if store.activeTier == .monthly {
                Button("Manage Subscription") { showManageSubscriptions = true }
                    .font(.footnote.weight(.semibold))
            }

            HStack(spacing: 20) {
                Button {
                    Task { await store.restore() }
                } label: {
                    if store.isRestoring {
                        ProgressView()
                    } else {
                        Text("Restore")
                    }
                }
                .disabled(isBusy)
                Text("•")
                Link("Terms", destination: URL(string: "https://sites.google.com/view/livo3dtermsofservice")!)
                Text("•")
                Link("Privacy", destination: URL(string: "https://sites.google.com/view/livo3dprivacypolicy")!)
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func benefitRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Color(rgb: 0x6366F1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
