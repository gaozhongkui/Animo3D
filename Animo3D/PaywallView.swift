import SwiftUI
import StoreKit

struct PaywallView: View {
    var onClose: () -> Void
    var source: String = "unknown"

    @ObservedObject private var store = ProStore.shared
    @State private var selectedTier = ProStore.Tier.monthly
    @State private var showManageSubscriptions = false

    private let accent = Color(rgb: 0x6366F1)
    private let pink = Color(rgb: 0xA855F7)
    private let benefits: [(icon: String, title: LocalizedStringKey)] = [
        ("person.2.fill", "Characters & Dances"),
        ("video.fill", "No Watermark"),
        ("photo.on.rectangle.angled", "Custom Stages")
    ]

    private var selectedProduct: Product? { store.product(for: selectedTier) }
    private var isBusy: Bool { store.purchasingID != nil || store.isRestoring }
    private var brandGradient: LinearGradient {
        LinearGradient(colors: [accent, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            background
            GeometryReader { geometry in
                let compact = geometry.size.height < 700
                ScrollView(showsIndicators: false) {
                    VStack(spacing: compact ? 14 : 24) {
                        header(compact: compact)
                        benefitsList(compact: compact)
                        if !store.isPro {
                            HStack(spacing: 12) {
                                planCard(.monthly, compact: compact)
                                planCard(.lifetime, compact: compact)
                            }
                        }
                        purchaseArea
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, compact ? 16 : 36)
                    .frame(maxWidth: 550)
                    .frame(minHeight: geometry.size.height, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.horizontal, 16)
                .padding(.top, 8)
        }
        .onAppear { Track.log(.paywallShown, ["source": source]) }
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

    private var background: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [accent.opacity(0.12), pink.opacity(0.04), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(accent.opacity(0.16))
                .frame(width: 380, height: 380)
                .blur(radius: 80)
                .offset(x: -140, y: -220)
            Circle()
                .fill(pink.opacity(0.12))
                .frame(width: 340, height: 340)
                .blur(radius: 80)
                .offset(x: 150, y: -120)
        }
        .ignoresSafeArea()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Close")
    }

    private func header(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 14) {
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 18 : 23, style: .continuous)
                    .fill(brandGradient)
                    .overlay {
                        RoundedRectangle(cornerRadius: compact ? 18 : 23, style: .continuous)
                            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                    }
                    .shadow(color: accent.opacity(0.28), radius: 18, x: 0, y: 10)
                Image(systemName: "crown.fill")
                    .font(.system(size: compact ? 26 : 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: compact ? 48 : 72, height: compact ? 48 : 72)

            VStack(spacing: 5) {
                Text("Livo 3D Pro")
                    .font(.system(size: compact ? 28 : 32, weight: .black, design: .rounded))
                Text(LocalizedStringKey(store.isPro ? "Pro Version Unlocked" : "Choose your Pro plan"))
                    .font(.system(size: compact ? 13 : 16, weight: .medium))
                    .foregroundStyle(accent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func benefitsList(compact: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(benefits.indices, id: \.self) { index in
                VStack(spacing: compact ? 6 : 8) {
                    Image(systemName: benefits[index].icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                        .background(brandGradient, in: RoundedRectangle(cornerRadius: 10))
                    Text(benefits[index].title)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(minHeight: 28)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, compact ? 8 : 14)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(accent.opacity(0.07), lineWidth: 1)
                }
                .shadow(color: accent.opacity(0.05), radius: 10, x: 0, y: 5)
            }
        }
    }

    private func planCard(_ tier: ProStore.Tier, compact: Bool) -> some View {
        let selected = selectedTier == tier
        let product = store.product(for: tier)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTier = tier
            }
            HapticManager.selection()
        } label: {
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                HStack {
                    Text(LocalizedStringKey(tier == .monthly ? "Monthly" : "Lifetime"))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(selected ? accent : Color(.tertiaryLabel))
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let product {
                        Text(product.displayPrice)
                            .font(.system(size: compact ? 25 : 28, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else if store.isLoadingProducts {
                        ProgressView().frame(height: 30)
                    } else {
                        Text("Unavailable").font(.subheadline)
                    }
                    Text(LocalizedStringKey(tier == .monthly ? "per month" : "One-time purchase"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(compact ? 12 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(brandGradient.opacity(0.09))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? accent : accent.opacity(0.12), lineWidth: selected ? 2 : 1)
            }
            .shadow(color: accent.opacity(selected ? 0.13 : 0.04), radius: 12, x: 0, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var purchaseArea: some View {
        VStack(spacing: 10) {
            if let tier = store.activeTier {
                Text(LocalizedStringKey(tier == .monthly ? "Monthly Subscription Active" : "Lifetime Access"))
                    .font(.subheadline.weight(.semibold))
                if tier == .monthly, let expiration = store.entitlement?.expirationDate {
                    Text("Access through \(expiration.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

            purchaseButton

            if !store.isPro {
                Text(LocalizedStringKey(
                    selectedTier == .monthly
                        ? "Auto-renews monthly. Cancel in App Store settings."
                        : "Lifetime access · No subscription"
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            if store.activeTier == .monthly {
                Button("Manage Subscription") { showManageSubscriptions = true }
                    .font(.footnote.weight(.semibold))
            }

            legalLinks
        }
        .tint(accent)
    }

    private var purchaseButton: some View {
        Button {
            guard !store.isPro, let product = selectedProduct else { return }
            Task { await store.purchase(product) }
        } label: {
            Group {
                if store.purchasingID != nil || (store.isLoadingProducts && selectedProduct == nil) {
                    ProgressView().tint(.white)
                } else if store.isPro {
                    Label("Pro Version Unlocked", systemImage: "checkmark.seal.fill")
                } else if let product = selectedProduct {
                    if selectedTier == .monthly {
                        Text("\(product.displayPrice) / month · Subscribe")
                    } else {
                        Text("\(product.displayPrice) · Unlock Forever")
                    }
                } else {
                    Text(LocalizedStringKey(
                        selectedTier == .monthly ? "Subscribe Monthly" : "Unlock Everything Forever"
                    ))
                }
            }
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(store.isPro ? Color.secondary : .white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                store.isPro
                    ? AnyShapeStyle(Color(.tertiarySystemFill))
                    : AnyShapeStyle(LinearGradient(
                        colors: [accent, Color(rgb: 0xA855F7)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
            )
            .clipShape(Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(store.isPro ? 0 : 0.2), lineWidth: 1)
            }
            .shadow(color: accent.opacity(store.isPro ? 0 : 0.24), radius: 14, x: 0, y: 7)
        }
        .disabled(store.isPro || selectedProduct == nil || isBusy)
    }

    private var legalLinks: some View {
        HStack(spacing: 16) {
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
            Text("·")
            Link("Terms", destination: URL(string: "https://sites.google.com/view/livo3dtermsofservice")!)
            Text("·")
            Link("Privacy", destination: URL(string: "https://sites.google.com/view/livo3dprivacypolicy")!)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
