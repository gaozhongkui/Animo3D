import SwiftUI

// UI dependencies unrelated to billing stay lightweight in the isolated test host.
extension Color {
    init(rgb: UInt) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

enum HapticManager {
    static func selection() {}
}

func L(_ value: String) -> String { NSLocalizedString(value, comment: "") }

extension View {
    func trackScreen(_ name: String) -> some View { self }
}
