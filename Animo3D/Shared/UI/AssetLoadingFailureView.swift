import SwiftUI

struct AssetLoadingFailureView: View {
    let failure: AssetLoadingFailure
    var closeTitle: LocalizedStringKey = "Cancel"
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            BrandLoading.ground.ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: failure.reason == .invalid || failure.reason == .rendering
                              ? "exclamationmark.triangle" : "icloud.slash")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(BrandLoading.cyan)
                            .frame(width: 80, height: 80)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24))

                        VStack(spacing: 12) {
                            Text(LocalizedStringKey(failure.title))
                                .font(.system(size: 23, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .accessibilityAddTraits(.isHeader)
                            Text(LocalizedStringKey(failure.message))
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                        VStack(spacing: 12) {
                            Button(action: onRetry) {
                                Label("Retry", systemImage: "arrow.clockwise")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .foregroundStyle(.white)
                                    .background(
                                        LinearGradient(
                                            colors: [.purple, Color(red: 0.44, green: 0.33, blue: 0.95)],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        in: RoundedRectangle(cornerRadius: 16)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("assetLoadingRetry")

                            Button(closeTitle, action: onClose)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .accessibilityIdentifier("assetLoadingCancel")
                        }
                    }
                    .frame(maxWidth: 340)
                    .padding(28)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }
}
