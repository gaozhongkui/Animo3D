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
//  Each variant here is the same idea in a different key: a lit stage seen from the floor. A
//  horizon splits a coloured back wall from a darker floor, a spotlight cone comes down from
//  the rig, a faint grid gives the floor its perspective, and a pool of light lands at the
//  performer's feet. The pool is what does the grounding - it reads as a floor without the card
//  needing to know where the feet actually are, which a drawn shadow would (the rendered figure is
//  centred, and its stance changes with every dance). The floor being the darkest part of the card
//  is deliberate: the dance title is printed there.
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

    /// The same accent for the SceneKit side, which lights the figure with it. The offscreen
    /// renderer has no other reason to import SwiftUI.
    static func accentUIColor(for style: Int) -> UIColor { UIColor(accent(for: style)) }

    /// Five keys, and what each one is for.
    ///
    /// The walls carry most of the colour, so they are what was wrong before: mixed at low
    /// saturation they came out as five shades of the same grey-violet, and the fifth - an
    /// olive-brown at 0x3B2412 - read as dirt rather than as stage light. They are saturated now,
    /// and the fifth is a rose rather than a brown. The accents are the light itself and are meant
    /// to be vivid: anything under about 80% saturation stops reading as a lamp and starts reading
    /// as haze once it has been blurred across a third of the card.
    ///
    /// Brightness was raised a second time, together with the three layers below that darken the
    /// card - the floor, the vignette and the foot. Dark enough to be a lit stage is not the same
    /// as dark, and the first pass took the walls down far enough that a screenful of cards read as
    /// black rectangles with a tint rather than as five different places.
    private var palette: Palette {
        switch ((style % 5) + 5) % 5 {
        case 0: return Palette(top: hex(0x2E3E9E), bottom: hex(0x141A3A),
                               accent: hex(0x5CE8FF), secondary: hex(0x9FA0FF))   // cyan / indigo
        case 1: return Palette(top: hex(0x6B1C74), bottom: hex(0x271430),
                               accent: hex(0xFF6BB4), secondary: hex(0xC183FF))   // pink / violet
        case 2: return Palette(top: hex(0x13556E), bottom: hex(0x0A2530),
                               accent: hex(0x4BEDD3), secondary: hex(0x5CBEFF))   // turquoise / blue
        case 3: return Palette(top: hex(0x422894), bottom: hex(0x191334),
                               accent: hex(0xC2A4FF), secondary: hex(0xFF93CB))   // lavender / pink
        default: return Palette(top: hex(0x82205B), bottom: hex(0x2B1220),
                                accent: hex(0xFFAE6B), secondary: hex(0xFF7BA8))  // amber / rose
        }
    }

    /// Where the back wall meets the floor. Every layer below is placed relative to this, so the
    /// card reads as one room rather than a stack of unrelated glows.
    private let horizon: CGFloat = 0.62

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let p = palette
            ZStack {
                // Back wall down to the floor. The floor is darker than the wall on purpose: it is
                // what the title sits on, and it is what stops the figure's feet.
                LinearGradient(stops: [
                    .init(color: p.top, location: 0.0),
                    .init(color: p.bottom, location: horizon),
                    .init(color: .black.opacity(0.46), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)

                // Spotlight cone: narrow at the rig, opening onto the floor. This is what makes the
                // card read as a lit stage rather than a coloured gradient - a glow alone has no
                // direction, and direction is the whole difference.
                Path { path in
                    path.move(to: CGPoint(x: w * 0.38, y: -h * 0.08))
                    path.addLine(to: CGPoint(x: w * 0.62, y: -h * 0.08))
                    path.addLine(to: CGPoint(x: w * 1.05, y: h * horizon))
                    path.addLine(to: CGPoint(x: -w * 0.05, y: h * horizon))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [p.accent.opacity(0.24), p.accent.opacity(0.0)],
                                     startPoint: .top, endPoint: .bottom))
                .blur(radius: w * 0.10)
                .blendMode(.screen)

                // Floor, in perspective: rows crowding together toward the horizon, and rails
                // converging on the vanishing point. Faint by design - at full strength this is a
                // synthwave poster, and the dance render has to stay the subject.
                Path { path in
                    let vp = CGPoint(x: w * 0.5, y: h * horizon)
                    for i in 1...5 {
                        let t = CGFloat(i) / 5
                        let y = h * (horizon + (1 - horizon) * t * t)   // t² = rows bunch up far away
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: w, y: y))
                    }
                    for i in -3...3 {
                        path.move(to: vp)
                        path.addLine(to: CGPoint(x: w * (0.5 + CGFloat(i) * 0.55), y: h))
                    }
                }
                .stroke(p.accent.opacity(0.17), lineWidth: 0.6)
                // Fade in below the horizon and out again before the bottom edge: a grid that runs
                // to the edge reads as wallpaper, and it would print itself through the title.
                .mask(LinearGradient(stops: [
                    .init(color: .clear, location: horizon),
                    .init(color: .white, location: horizon + 0.08),
                    .init(color: .clear, location: 0.92),
                ], startPoint: .top, endPoint: .bottom))

                // Rim light behind the shoulders, thrown left of centre. Centred and wide, it sat
                // directly behind the head and the pale render dissolved into it.
                Circle()
                    .fill(RadialGradient(colors: [p.accent.opacity(0.40), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.40))
                    .frame(width: w * 0.86, height: w * 0.86)
                    .blur(radius: w * 0.14)
                    .position(x: w * 0.38, y: h * 0.26)
                    .blendMode(.screen)

                // Off-axis fill in the secondary colour, so the light is not symmetric.
                Circle()
                    .fill(RadialGradient(colors: [p.secondary.opacity(0.38), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.28))
                    .frame(width: w * 0.58, height: w * 0.58)
                    .blur(radius: w * 0.13)
                    .position(x: w * 0.82, y: h * 0.16)
                    .blendMode(.screen)

                // Pool at the feet. Sits just below the horizon, not at the bottom edge, so it
                // grounds the figure instead of lighting up the strip the title occupies.
                Ellipse()
                    .fill(RadialGradient(colors: [p.accent.opacity(0.40), .clear],
                                         center: .center, startRadius: 0, endRadius: w * 0.38))
                    .frame(width: w * 0.95, height: h * 0.17)
                    .blur(radius: w * 0.07)
                    .position(x: w * 0.5, y: h * 0.78)
                    .blendMode(.screen)

                // Sheen on the top edge: catches the card's own rounded corner, the way glass does.
                LinearGradient(stops: [
                    .init(color: .white.opacity(0.09), location: 0),
                    .init(color: .clear, location: 0.20),
                ], startPoint: .top, endPoint: .bottom)
                .blendMode(.plusLighter)

                // Vignette, then a dark foot. The foot is the card's own readability scrim: with it
                // here the caller only needs a light one, instead of crushing half the render.
                RadialGradient(colors: [.clear, .black.opacity(0.28)],
                               center: .init(x: 0.5, y: 0.40), startRadius: w * 0.34, endRadius: w * 1.05)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.60),
                    .init(color: .black.opacity(0.38), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
            // Opaque ground under the alpha stops above, so the card never shows what is behind it.
            .background(p.bottom)
            .compositingGroup()
        }
    }

    private func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue: Double(v & 0xFF) / 255)
    }
}
