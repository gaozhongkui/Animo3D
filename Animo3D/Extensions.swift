//
//  Extensions.swift
//  Animo3D
//

import Foundation
import UIKit
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
    static func getCacheSize() -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("sketchfab_usdz")

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 KB"
        }

        var totalSize: Int64 = 0
        for file in files {
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey])
            totalSize += Int64(attrs?.fileSize ?? 0)
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }

    static func clearCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("sketchfab_usdz")
        try? FileManager.default.removeItem(at: dir)
    }
}
