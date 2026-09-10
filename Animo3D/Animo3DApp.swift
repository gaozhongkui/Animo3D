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

    /// Firebase is configured here rather than in a `.task`, because `Track.start()` has to have
    /// run before the first event can be logged and the splash screen already logs one.
    init() {
        Track.start()
        Track.setDeviceTier()
        Track.setPro(ProStore.shared.isPro)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMainView {
                RootTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.1)))
                } else {
                    SplashView(isActive: $showMainView)
                }
            }
            // The index is the only asset config, and every grid needs it, so the fetch starts
            // before the first screen is drawn rather than when a list first appears.
            .task { RemoteAssets.shared.start() }
        }
    }
}
