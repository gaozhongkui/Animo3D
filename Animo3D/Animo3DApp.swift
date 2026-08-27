//
//  Animo3DApp.swift
//  Animo3D
//
//  Created by gaozhongkui on 2026/8/7.
//

import SwiftUI

@main
struct Animo3DApp: App {
    @State private var showMainView = false

    var body: some Scene {
        WindowGroup {
            if showMainView {
                RootTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.1)))
            } else {
                SplashView(isActive: $showMainView)
            }
        }
    }
}
