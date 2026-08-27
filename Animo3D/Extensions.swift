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
