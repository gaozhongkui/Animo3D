import SwiftUI
import StoreKit

struct PaywallView: View {
    var onClose: () -> Void
    var source: String = "unknown"

    @ObservedObject private var store = ProStore.shared
    @State private var selectedTier = ProStore.Tier.monthly
    @State private var showManageSubscriptions = false

    private let accent = Color(rgb: 0x6366F1)
    private let benefits: [(icon: String, title: LocalizedStringKey)] = [
        ("person.2.fill", "All Characters & Dances"),
        ("video.fill", "No Watermark"),
        ("photo.on.rectangle.angled", "More Stages & Custom Backgrounds")
    ]

    private var selectedProduct: Product? { store.product(for: selectedTier) }
    private var isBusy: Bool { store.purchasingID != nil || store.isRestoring }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            LinearGradient(
                colors: [accent.opacity(0.08), Color(.systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    benefitsList
                    if !store.isPro {
                        VStack(spacing: 10) {
                            planCard(.monthly)
                            planCard(.lifetime)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 550)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            purchaseArea
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: 550)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(accent)
            Text("Livo 3D Pro")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var benefitsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(benefits.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    Image(systemName: benefits[index].icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 24)
                    Text(benefits[index].title)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 20, alignment: .leading)
            }
        }
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
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? accent : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(tier == .monthly ? "Monthly" : "Lifetime"))
                        .font(.subheadline.weight(.semibold))
                    Text(LocalizedStringKey(tier == .monthly ? "Cancel anytime" : "One-time purchase"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let product {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice).font(.headline)
                        if tier == .monthly {
                            Text("per month")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if store.isLoadingProducts {
                    ProgressView()
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(selected ? accent : Color(.separator).opacity(0.3), lineWidth: selected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
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
