//
//  SharedUI.swift
//  Animo3D
//
//  全 App 统一的圆形返回/关闭按钮，保证各页风格一致。
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
