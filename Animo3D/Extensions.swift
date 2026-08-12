//
//  Extensions.swift
//  Animo3D
//

import Foundation

extension Int {
    var formattedAbbreviated: String {
        if self >= 1000 {
            return String(format: "%.1fK", Double(self) / 1000.0)
        }
        return "\(self)"
    }
}
