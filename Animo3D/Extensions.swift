//
//  Extensions.swift
//  Animo3D
//

import Foundation
import UIKit

/// Localized-string lookup for call sites that need a plain `String`
/// (UIKit labels, status messages) instead of SwiftUI's `LocalizedStringKey`.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
import SwiftUI

extension Int {
    var formattedAbbreviated: String {
        if self >= 1000 {
            return String(format: "%.1fK", Double(self) / 1000.0)
        }
        return "\(self)"
    }
}

extension UIFont {
    static func roundedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let systemFont = UIFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = systemFont.fontDescriptor.withDesign(.rounded) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return systemFont
    }
}

extension UIColor {
    convenience init(rgb: UInt) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF)/255,
                  green: CGFloat((rgb >> 8) & 0xFF)/255,
                  blue: CGFloat(rgb & 0xFF)/255,
                  alpha: 1)
    }
}

extension Color {
    init(rgb: UInt) {
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

// MARK: - Haptic Feedback

enum HapticManager {
    static func light() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    static func medium() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }
}

// MARK: - Cache Management

enum StorageManager {
    /// Reports on, and clears, the downloaded community models. Both used to reach into
    /// `Caches/sketchfab_usdz` by hand, in two places, with the path spelled out each time - so
    /// when the models moved out of Caches the settings row would have gone on reporting "0 KB"
    /// about an empty directory while the real files sat elsewhere. One source of truth now.
    static func getCacheSize() -> String {
        let fm = FileManager.default
        let dir = SketchfabClient.modelsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 KB"
        }
        let total = files.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    static func clearCache() {
        let fm = FileManager.default
        let dir = SketchfabClient.modelsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        // The files, not the directory: `modelsDirectory` is a `static let` that created and
        // configured it once, so removing it would leave every later download writing into a
        // directory that no longer exists.
        for file in files { try? fm.removeItem(at: file) }
    }
}
