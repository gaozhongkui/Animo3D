//
//  SharedUI.swift
//  Animo3D
//
//  The app-wide circular back/close button, which keeps every page consistent.
//

import SwiftUI

struct CircleButton: View {
    let system: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        }
    }
}
