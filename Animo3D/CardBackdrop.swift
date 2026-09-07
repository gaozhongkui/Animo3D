//
//  CardBackdrop.swift
//  Animo3D
//
//  The backdrop behind a dance or character card: a dark stage, lit.
//
//  What this replaced, and why: five candy-pastel gradients - peach, pink, mint, a rainbow angular
//  sweep - each scattered with white `heart.fill` / `star.fill` / `sparkle` symbols at fixed
//  fractional positions. Three things were wrong with it. The palette fought the app: every other
//  screen is a dark neon stage, so the grid read as a different product bolted on. A character
//  rendered on transparent black sat on top of pale mint as a cut-out with no grounding. And the
//  symbols were decoration standing in for composition - they made every card busy without making
//  any card informative.
//
//  Each variant here is the same idea in a different key: a dark ground, one coloured rim glow
//  behind the performer's shoulders, and a pool of light at their feet. The pool is what does the
//  work - it reads as a floor without the card needing to know where the feet actually are, which a
//  drawn shadow would (the rendered figure is centred, and its stance changes with every dance).
//

import SwiftUI

struct CardBackdrop: View {
    let style: Int

    /// Accent per variant: the rim glow above, the floor pool below.
    struct Palette {
        let top: Color, bottom: Color, accent: Color, secondary: Color
    }

    /// The accent a card of this style is lit with. Exposed so a selected card can glow in its own
    /// colour: the system blue looked bolted on next to a teal or amber card.
    static func accent(for style: Int) -> Color { Self(style: style).palette.accent }

    private var palette: Palette {
        switch ((style % 5) + 5) % 5 {
        case 0: return Palette(top: hex(0x241A4D), bottom: hex(0x0D0B1F),
                               accent: hex(0x6EE7FF), secondary: hex(0xB794FF))   // cyan / violet
        case 1: return Palette(top: hex(0x3A1436), bottom: hex(0x120A18),
                               accent: hex(0xFF6EC7), secondary: hex(0xFFB86E))   // magenta / amber
        case 2: return Palette(top: hex(0x102E3E), bottom: hex(0x07131C),
                               accent: hex(0x34E2C4), secondary: hex(0x4D9BFF))   // teal / blue
        case 3: return Palette(top: hex(0x2C1B4A), bottom: hex(0x0F0A1C),
                               accent: hex(0xA678FF), secondary: hex(0xFF7AC8))   // violet / pink
        default: return Palette(top: hex(0x3B2412), bottom: hex(0x150C08),
                                accent: hex(0xFFA23A), secondary: hex(0xFF5E7A))  // amber / coral
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let p = palette
            ZStack {
                LinearGradient(colors: [p.top, p.bottom], startPoint: .top, endPoint: .bottom)

                // Rim glow, upper third: sits behind the head and shoulders and separates the
                // figure from the ground, the way the stage's back light does.
                Circle()
                    .fill(p.accent.opacity(0.38))
                    .frame(width: w * 1.05, height: w * 1.05)
                    .blur(radius: w * 0.30)
                    .position(x: w * 0.5, y: h * 0.30)

                // Second, offset accent so the light is not perfectly symmetric.
                Circle()
                    .fill(p.secondary.opacity(0.26))
                    .frame(width: w * 0.7, height: w * 0.7)
                    .blur(radius: w * 0.26)
                    .position(x: w * 0.78, y: h * 0.20)

                // Floor pool: a flattened ellipse low in the card. This is the grounding cue.
                // Blurred as well as gradient-filled - the gradient alone still left a visible
                // elliptical edge where the shape ended, which read as a drawn oval rather than light.
                Ellipse()
                    .fill(
                        RadialGradient(colors: [p.accent.opacity(0.50), p.accent.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: w * 0.50)
                    )
                    .frame(width: w * 1.25, height: h * 0.22)
                    .blur(radius: w * 0.06)
                    .position(x: w * 0.5, y: h * 0.84)

                // Vignette: pulls the corners down so the card frames the performer.
                RadialGradient(colors: [.clear, .black.opacity(0.55)],
                               center: .center, startRadius: w * 0.30, endRadius: w * 0.95)
            }
            .compositingGroup()
        }
    }

    private func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}
