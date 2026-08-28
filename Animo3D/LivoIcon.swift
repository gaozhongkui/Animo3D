//
//  LivoIcon.swift
//  Livo 3D
//
//  基于 SwiftUI 的 App Icon 设计。
//  您可以以此为蓝图生成正式的 App Icon。
//

import SwiftUI

struct LivoIcon: View {
    var body: some View {
        ZStack {
            // 背景渐变：深邃的靛蓝到紫色的弥散效果
            LinearGradient(
                colors: [Color(rgb: 0x6366F1), Color(rgb: 0xA855F7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // 装饰元素：流动的光影
            Circle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 300, height: 300)
                .blur(radius: 40)
                .offset(x: 100, y: -120)

            VStack(spacing: -10) {
                // 核心符号：闪耀的星星，代表 AR 与灵感
                Image(systemName: "sparkles")
                    .font(.system(size: 140, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.1), radius: 10, y: 5)

                // 字母 "L"，代表 Livo
                Text("L")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(x: -40, y: -20)
            }
        }
        .frame(width: 512, height: 512) // 标准图标尺寸
        .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
    }
}

#Preview {
    LivoIcon()
        .scaleEffect(0.5)
}
