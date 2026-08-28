//
//  CardBackdrop.swift
//  Animo3D
//
//  Decorative backgrounds for dance cards: bokeh / sparkle / hearts / stars / rainbow, cycled in order, which reads richer than a plain gradient.
//

import SwiftUI

struct CardBackdrop: View {
    let style: Int
    private var s: Int { ((style % 5) + 5) % 5 }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                base
                motifs(w: w, h: h)
            }
            .compositingGroup()
        }
    }

    private var base: some View {
        Group {
            switch s {
            case 0: LinearGradient(colors: [hex(0x3A2C6E), hex(0x1E2A5E)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 1: LinearGradient(colors: [hex(0xF7C9A0), hex(0xE79079)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 2: LinearGradient(colors: [hex(0xFFD6EC), hex(0xFF9DC6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case 3: LinearGradient(colors: [hex(0xC6F0D6), hex(0x86D9C0)], startPoint: .topLeading, endPoint: .bottomTrailing)
            default: AngularGradient(colors: [hex(0xFFC1E3), hex(0xC1D6FF), hex(0xC6F5E0), hex(0xFFF0B3), hex(0xFFC1E3)],
                                     center: .center)
            }
        }
    }

    @ViewBuilder
    private func motifs(w: CGFloat, h: CGFloat) -> some View {
        switch s {
        case 0: // Bokeh
            blob(hex(0x6EE7FF), 0.55*w, 0.22, 0.20)
            blob(hex(0xB794FF), 0.6*w, 0.75, 0.30)
            blob(hex(0x5A7BFF), 0.45*w, 0.5, 0.7)
        case 1: // Sparkle
            sym("sparkle", 22, 0.25, 0.22); sym("sparkle", 14, 0.7, 0.35)
            sym("sparkle", 18, 0.5, 0.72); sym("sparkle", 12, 0.8, 0.8)
        case 2: // Hearts
            sym("heart.fill", 20, 0.22, 0.24); sym("heart.fill", 13, 0.75, 0.3)
            sym("heart.fill", 16, 0.5, 0.7); sym("heart.fill", 11, 0.82, 0.78)
        case 3: // Stars
            sym("star.fill", 20, 0.24, 0.22); sym("star.fill", 13, 0.72, 0.32)
            sym("star.fill", 15, 0.48, 0.72); sym("star.fill", 11, 0.8, 0.8)
        default: // Rainbow with a touch of sparkle
            sym("sparkle", 18, 0.3, 0.25); sym("sparkle", 13, 0.72, 0.7)
        }
    }

    private func blob(_ c: Color, _ d: CGFloat, _ fx: CGFloat, _ fy: CGFloat) -> some View {
        Circle().fill(c.opacity(0.55)).frame(width: d, height: d).blur(radius: 22)
            .modifier(PositionFrac(fx: fx, fy: fy))
    }

    private func sym(_ name: String, _ size: CGFloat, _ fx: CGFloat, _ fy: CGFloat) -> some View {
        Image(systemName: name).font(.system(size: size)).foregroundStyle(.white.opacity(0.55))
            .modifier(PositionFrac(fx: fx, fy: fy))
    }

    private func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF)/255, green: Double((v >> 8) & 0xFF)/255, blue: Double(v & 0xFF)/255)
    }
}

/// Positioned as a fraction of the parent container.
private struct PositionFrac: ViewModifier {
    let fx: CGFloat; let fy: CGFloat
    func body(content: Content) -> some View {
        GeometryReader { g in
            content.position(x: g.size.width * fx, y: g.size.height * fy)
        }
    }
}
