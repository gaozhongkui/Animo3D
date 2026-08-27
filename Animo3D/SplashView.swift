//
//  SplashView.swift
//  Animo3D
//
//  启动闪屏页：展示品牌 Logo 动画。
//

import SwiftUI

struct SplashView: View {
    @Binding var isActive: Bool
    @State private var scale = 0.7
    @State private var opacity = 0.4

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Logo 图标
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 120, height: 120)
                        .blur(radius: 20)
                        .opacity(0.3)

                    Image(systemName: "sparkles")
                        .font(.system(size: 80, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .scaleEffect(scale)
                .opacity(opacity)

                // App 名称
                VStack(spacing: 8) {
                    Text("Animo3D")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .tracking(2)

                    Text("让空间充满舞蹈")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .kerning(4)
                }
                .offset(y: 20)
                .opacity(opacity)
            }
        }
        .onAppear {
            withAnimation(.easeIn(duration: 1.2)) {
                self.scale = 1.0
                self.opacity = 1.0
            }

            // 2.5秒后切换到主界面
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation {
                    self.isActive = true
                }
            }
        }
    }
}

#Preview {
    SplashView(isActive: .constant(false))
}
