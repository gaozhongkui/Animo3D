import SwiftUI
import StoreKit

struct PaywallView: View {
    var onClose: () -> Void
    var source: String = "unknown"

    @ObservedObject private var store = ProStore.shared
    @State private var selectedTier = ProStore.Tier.monthly
    @State private var showManageSubscriptions = false
    @State private var hasCheckedEntitlements = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let accent = Color(rgb: 0x7555E8)
    private let stageColor = Color(rgb: 0x201335)
    private let benefits: [(icon: String, title: LocalizedStringKey)] = [
        ("person.2.fill", "All Characters & Dances"),
        ("video.fill", "No Watermark"),
        ("photo.on.rectangle.angled", "More Stages & Custom Backgrounds")
    ]

    private var selectedProduct: Product? { store.product(for: selectedTier) }
    private var isBusy: Bool { store.purchasingID != nil || store.isRestoring }
    private var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, Color(rgb: 0xA16AF0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 720 {
                    wideLayout(size: geometry.size)
                } else {
                    phoneLayout(size: geometry.size)
                }
            }
            .background(Color(.systemBackground).ignoresSafeArea())
        }
        .tint(accent)
        .onAppear { Track.log(.paywallShown, ["source": source]) }
        .task {
            await store.refreshEntitlements()
            hasCheckedEntitlements = true
            if store.products.isEmpty {
                await store.loadProducts()
            }
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .alert(
            "Purchase unavailable",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(L(store.lastError ?? ""))
        }
        .trackScreen("Paywall")
    }

    private func phoneLayout(size: CGSize) -> some View {
        let compact = size.height < 720
        return VStack(spacing: 0) {
            HStack {
                brandMark(onDark: false)
                Spacer()
                closeButton
            }
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.vertical, 4)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: compact ? 16 : 22) {
                    phoneIntroduction(compact: compact)
                    benefitsList(compact: compact)
                    planOptions(compact: compact)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                purchaseArea
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
            }
        }
    }

    @ViewBuilder
    private func phoneIntroduction(compact: Bool) -> some View {
        if compact {
            HStack(spacing: 16) {
                showcase(height: 76)
                    .frame(width: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                purchaseHeader(wide: false)
            }
        } else {
            showcase(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .accessibilityHidden(true)
            purchaseHeader(wide: false)
        }
    }

    private func wideLayout(size: CGSize) -> some View {
        let short = size.height < 600
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: short ? 16 : 28) {
                brandMark(onDark: true)
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Create without limits.")
                        .font(.system(
                            size: short ? 28 : (size.width < 1000 ? 42 : 54),
                            weight: .bold,
                            design: .rounded
                        ))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if !short {
                        Text("Bring your characters to life.")
                            .font(.title3)
                            .foregroundStyle(Color(rgb: 0xD4C4EB))
                    }
                }
                showcase(height: short ? 120 : min(460, size.width * 0.36))
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
            }
            .padding(short ? 20 : (size.width < 1000 ? 32 : 48))
            .frame(width: size.width * 0.46)
            .frame(maxHeight: .infinity)
            .background(stageColor.ignoresSafeArea(edges: [.top, .bottom, .leading]))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    purchaseHeader(wide: true)
                    benefitsList(compact: false)
                    planOptions(compact: short)
                    purchaseArea
                }
                .padding(.horizontal, size.width < 1000 ? 28 : 44)
                .padding(.vertical, short ? 28 : 72)
                .frame(maxWidth: 550)
                .frame(minHeight: size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(12)
        }
    }

    private func brandMark(onDark: Bool) -> some View {
        HStack(spacing: 9) {
            Text("Livo 3D")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(onDark ? .white : .primary)
            Text("PRO")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundStyle(onDark ? stageColor : .white)
                .background(onDark ? AnyShapeStyle(Color(rgb: 0xE6D7FF)) : AnyShapeStyle(brandGradient))
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemFill), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Close")
    }

    private func showcase(height: CGFloat) -> some View {
        GeometryReader { geometry in
            let cardHeight = min(height * 0.88, geometry.size.width * 0.66)
            let cardWidth = cardHeight * 0.69
            ZStack {
                stageColor
                Ellipse()
                    .stroke(Color(rgb: 0xBDA2E8).opacity(0.18), lineWidth: 1)
                    .frame(width: geometry.size.width * 0.9, height: height * 0.28)
                    .offset(y: height * 0.36)
                artworkCard(
                    image: "ProDanceFreestyle",
                    title: "FREESTYLE",
                    background: Color(rgb: 0xE9DDF9),
                    width: cardWidth,
                    height: cardHeight
                )
                .rotationEffect(.degrees(-12))
                .offset(x: -cardWidth * 0.47, y: height * 0.02)
                artworkCard(
                    image: "ProDanceHipHop",
                    title: "HIP HOP",
                    background: Color(rgb: 0xF6BCA6),
                    width: cardWidth,
                    height: cardHeight
                )
                .rotationEffect(.degrees(10))
                .offset(x: cardWidth * 0.47, y: -height * 0.015)
                Image(systemName: "sparkle")
                    .font(.system(size: height < 200 ? 20 : 32, weight: .light))
                    .foregroundStyle(Color(rgb: 0xE1C5FF))
                    .offset(x: -geometry.size.width * 0.36, y: -height * 0.28)
                Image(systemName: "sparkle")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(Color(rgb: 0xF4D3A3))
                    .offset(x: geometry.size.width * 0.37, y: height * 0.23)
            }
            .frame(width: geometry.size.width, height: height)
            .clipped()
        }
        .frame(height: height)
    }

    private func artworkCard(
        image: String,
        title: String,
        background: Color,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            background
            Image(image)
                .resizable()
                .scaledToFit()
                .padding(.bottom, height * 0.06)
            if height > 125 {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text(verbatim: title)
                        .tracking(1)
                }
                .font(.system(size: min(11, height * 0.04), weight: .bold))
                .lineLimit(1)
                .foregroundStyle(stageColor)
                .padding(width * 0.1)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: height * 0.07))
        .overlay {
            RoundedRectangle(cornerRadius: height * 0.07)
                .strokeBorder(.white.opacity(0.4), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 14)
    }

    private func purchaseHeader(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if wide {
                Text("Livo 3D Pro")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
            }
            Text(LocalizedStringKey(
                store.isPro
                    ? "Pro Version Unlocked"
                    : (wide ? "Choose your Pro plan" : "Create without limits.")
            ))
            .font(.system(size: wide ? 34 : 28, weight: .bold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefitsList(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            ForEach(benefits.indices, id: \.self) { index in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: benefits[index].icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    Text(benefits[index].title)
                        .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func planOptions(compact: Bool) -> some View {
        VStack(spacing: 10) {
            planRow(.monthly, compact: compact)
            planRow(.lifetime, compact: compact)
        }
    }

    private func planRow(_ tier: ProStore.Tier, compact: Bool) -> some View {
        let purchased = store.activeTier == tier
        let selected = store.activeTier.map { $0 == tier } ?? (selectedTier == tier)
        let product = store.product(for: tier)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedTier = tier
            }
            HapticManager.selection()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: purchased ? "checkmark.seal.fill" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(purchased ? .green : (selected ? accent : Color(.tertiaryLabel)))
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        planDescription(tier)
                        planPrice(product, tier: tier, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 12) {
                        planDescription(tier)
                            .layoutPriority(1)
                        Spacer(minLength: 4)
                        planPrice(product, tier: tier, alignment: .trailing)
                    }
                }
            }
            .padding(compact ? 12 : 16)
            .frame(minHeight: compact ? 64 : 76)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? accent.opacity(0.07) : Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        selected ? accent : Color(.separator).opacity(0.25),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || store.isPro || !hasCheckedEntitlements || store.isRefreshingEntitlements)
        .accessibilityIdentifier("paywall.plan.\(tier.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func planDescription(_ tier: ProStore.Tier) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(tier == .monthly ? "Monthly" : "Lifetime"))
                .font(.subheadline.weight(.semibold))
            if store.activeTier == tier {
                Text(LocalizedStringKey(tier == .monthly ? "Current Plan" : "Purchased"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Text(LocalizedStringKey(tier == .monthly ? "Cancel anytime" : "One-time purchase"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func planPrice(
        _ product: Product?,
        tier: ProStore.Tier,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let product {
                Text(product.displayPrice)
                    .font(.title3.weight(.bold))
                    .fixedSize()
            } else if store.isLoadingProducts {
                ProgressView()
            } else {
                Text("Unavailable")
                    .font(.caption)
            }
            if tier == .monthly {
                Text("per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            guard hasCheckedEntitlements, !store.isRefreshingEntitlements,
                  !store.isPro, !isBusy, let product = selectedProduct else { return }
            Task { await store.purchase(product) }
        } label: {
            Group {
                if store.isPro {
                    Label("Pro Version Unlocked", systemImage: "checkmark.seal.fill")
                } else if !hasCheckedEntitlements || store.isRefreshingEntitlements
                    || store.purchasingID != nil || (store.isLoadingProducts && selectedProduct == nil) {
                    ProgressView().tint(.white)
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
                    : AnyShapeStyle(brandGradient)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(store.isPro ? 0 : 0.2), lineWidth: 1)
            }
            .shadow(color: accent.opacity(store.isPro ? 0 : 0.24), radius: 14, x: 0, y: 7)
        }
        .disabled(store.isPro || !hasCheckedEntitlements || store.isRefreshingEntitlements
                  || selectedProduct == nil || isBusy)
        .accessibilityIdentifier("paywall.purchase")
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
