//
//  PaywallView.swift
//  Animo3D
//
//  Pro Paywall: unlock all characters/dances, remove the watermark, no ads.
//  Sold as a subscription (weekly / monthly / yearly) or a one-off lifetime unlock - see ProStore.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    var onClose: () -> Void
    @ObservedObject private var store = ProStore.shared
    @State private var animateItems = false
    @State private var selectedID: String?

    /// The plan the CTA will buy. Defaults to the first offer (yearly) once products arrive.
    private var selected: Product? {
        store.products.first { $0.id == selectedID } ?? store.products.first
    }

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

                        plansSection
                            .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 200)
                }
            }

            // Bottom action area
            VStack {
                Spacer()

                bottomActions
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
        .alert("Purchase", isPresented: Binding(get: { store.lastError != nil },
                                                set: { if !$0 { store.lastError = nil } })) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    // MARK: - Plans

    @ViewBuilder
    private var plansSection: some View {
        if store.isPro {
            EmptyView()
        } else if store.products.isEmpty {
            VStack(spacing: 10) {
                if store.loadFailed {
                    Text("Could not reach the App Store.")
                        .font(.system(size: 14, weight: .semibold))
                    Button("Try again") { Task { await store.loadProducts() } }
                        .font(.system(size: 13, weight: .bold))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(spacing: 10) {
                ForEach(store.products, id: \.id) { p in
                    planRow(p)
                }
            }
        }
    }

    private func planRow(_ p: Product) -> some View {
        let isSelected = selected?.id == p.id
        let period = store.periodText(for: p)
        let intro = store.introOfferText(for: p)
        return Button {
            HapticManager.light()
            selectedID = p.id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color(rgb: 0x6366F1) : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(p.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color(.label))
                    if let intro {
                        Text(intro + ", then " + p.displayPrice + (period.map { " / " + $0 } ?? ""))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if let period {
                        Text(p.displayPrice + " / " + period)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("One-time payment")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(p.displayPrice)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(.label))
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color(rgb: 0x6366F1) : Color(.label).opacity(0.06),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Bottom actions

    @ViewBuilder
    private var bottomActions: some View {
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
                purchaseButton
                disclosureText
                legalRow
            }
        }
    }

    @ViewBuilder
    private var purchaseButton: some View {
        let p = selected
        let busy = p.map { store.purchasingID == $0.id } ?? false
        Button {
            guard let p, !busy else { return }
            HapticManager.medium()
            Task { await store.purchase(p) }
        } label: {
            VStack(spacing: 2) {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Text(ctaTitle).font(.system(size: 18, weight: .bold))
                    if let sub = ctaSubtitle {
                        Text(sub).font(.system(size: 11, weight: .medium)).opacity(0.8)
                    }
                }
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
        .disabled(p == nil || busy)
        .opacity(p == nil ? 0.5 : 1)
    }

    private var ctaTitle: String {
        guard let p = selected else { return "Continue" }
        if let intro = store.introOfferText(for: p) { return "Start " + intro }
        return p.subscription == nil ? "Unlock Forever" : "Continue"
    }

    private var ctaSubtitle: String? {
        guard let p = selected else { return nil }
        guard let period = store.periodText(for: p) else { return "Lifetime access · No subscription" }
        if store.introOfferText(for: p) != nil {
            return "Then " + p.displayPrice + " / " + period + " · Cancel anytime"
        }
        return p.displayPrice + " / " + period + " · Cancel anytime"
    }

    /// App Review requires the renewal terms next to the button, not buried in a linked document.
    @ViewBuilder
    private var disclosureText: some View {
        if selected?.subscription != nil {
            Text("Payment is charged to your Apple ID at confirmation. The subscription renews automatically unless it is cancelled at least 24 hours before the period ends. Manage or cancel it in your Apple ID settings.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
    }

    /// The same two URLs that go in App Store Connect, so the binding subscription terms have a
    /// single source of truth - an in-app copy drifts the moment the hosted page is edited.
    private static let termsURL = URL(string: "https://sites.google.com/view/livo3dtermsofservice")!
    private static let privacyURL = URL(string: "https://sites.google.com/view/livo3dprivacypolicy")!

    private var legalRow: some View {
        HStack(spacing: 20) {
            Button("Restore") { Task { await store.restore() } }
                .disabled(store.isRestoring)
            Text("•")
            Link("Terms", destination: Self.termsURL)
            Text("•")
            Link("Privacy", destination: Self.privacyURL)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
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
