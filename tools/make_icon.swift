//
//  make_icon.swift
//  Animo3D / tools
//
//  Draws the app icon (1024x1024, the three iOS 18 appearances) instead of hand-editing a PNG,
//  so the mark can be re-tuned by changing numbers here.
//
//  The mark: a figure caught mid-dance, trailed by motion arcs, standing on the ellipse of light
//  that the app projects a character onto in AR. Legible down to a 40pt home-screen tile because it
//  is one bold silhouette rather than a rendered character.
//
//  Build & run:
//      swiftc -O tools/make_icon.swift -o /tmp/make_icon && /tmp/make_icon <out-dir>
//

import Foundation
import AppKit
import CoreGraphics

let S: CGFloat = 1024

enum Variant { case light, dark, tinted }

// MARK: - Geometry (a single dancing pose, in 1024-space)

struct Pose {
    let head = CGPoint(x: 566, y: 300)
    let headR: CGFloat = 64
    let neck = CGPoint(x: 552, y: 382)
    let chest = CGPoint(x: 530, y: 452)
    let hip = CGPoint(x: 498, y: 600)

    // raised arm, thrown up and back
    let armAElbow = CGPoint(x: 654, y: 404)
    let armAHand = CGPoint(x: 706, y: 252)
    // trailing arm, swept low across the body
    let armBElbow = CGPoint(x: 408, y: 486)
    let armBHand = CGPoint(x: 322, y: 392)

    // planted leg
    let legAKnee = CGPoint(x: 566, y: 736)
    let legAFoot = CGPoint(x: 548, y: 862)
    // kicked-out leg
    let legBKnee = CGPoint(x: 392, y: 706)
    let legBFoot = CGPoint(x: 282, y: 790)

    let stage = CGPoint(x: 512, y: 872)
    let stageRX: CGFloat = 306
    let stageRY: CGFloat = 74
}

let pose = Pose()

func limb(_ ctx: CGContext, _ pts: [CGPoint], width: CGFloat) {
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: pts[0])
    for p in pts.dropFirst() { ctx.addLine(to: p) }
    ctx.strokePath()
}

// MARK: - Drawing

func drawIcon(_ ctx: CGContext, variant: Variant) {
    let full = CGRect(x: 0, y: 0, width: S, height: S)
    ctx.setShouldAntialias(true)

    // --- background
    let space = CGColorSpaceCreateDeviceRGB()
    let stops: [CGFloat] = [0, 0.55, 1]
    let colors: [CGColor]
    switch variant {
    case .light:
        // Violet into magenta into a warm stage light: reads as "performance", not "utility".
        colors = [CGColor(red: 0.36, green: 0.20, blue: 0.86, alpha: 1),
                  CGColor(red: 0.72, green: 0.20, blue: 0.72, alpha: 1),
                  CGColor(red: 0.99, green: 0.44, blue: 0.36, alpha: 1)]
    case .dark:
        colors = [CGColor(red: 0.07, green: 0.05, blue: 0.16, alpha: 1),
                  CGColor(red: 0.20, green: 0.08, blue: 0.30, alpha: 1),
                  CGColor(red: 0.36, green: 0.12, blue: 0.32, alpha: 1)]
    case .tinted:
        // Apple recolours this one from its luminance, so it has to be pure greyscale.
        colors = [CGColor(gray: 0.06, alpha: 1), CGColor(gray: 0.14, alpha: 1), CGColor(gray: 0.24, alpha: 1)]
    }
    // Only the default appearance paints its own background. Apple composites the dark and tinted
    // variants over a backdrop it supplies, and expects those to arrive on transparency.
    if variant == .light, let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    }

    // The pose above is written top-down, the way it reads on paper; a bitmap context is bottom-up.
    // Flip once here, then inset: iOS masks the icon to a rounded rect, so the mark has to keep
    // clear of the corners.
    ctx.translateBy(x: 0, y: S)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: S / 2, y: S / 2)
    ctx.scaleBy(x: 0.86, y: 0.86)
    ctx.translateBy(x: -S / 2 - 16, y: -S / 2 - 10)

    // --- stage: the pool of light the character is projected onto
    let stageAlpha: CGFloat = variant == .light ? 0.30 : 0.26
    ctx.saveGState()
    let stageRect = CGRect(x: pose.stage.x - pose.stageRX, y: pose.stage.y - pose.stageRY,
                           width: pose.stageRX * 2, height: pose.stageRY * 2)
    ctx.setFillColor(CGColor(gray: 1, alpha: stageAlpha))
    ctx.fillEllipse(in: stageRect)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: stageAlpha + 0.30))
    ctx.setLineWidth(9)
    ctx.strokeEllipse(in: stageRect)
    ctx.restoreGState()

    // --- motion arcs: three trailing crescents on the side the raised arm swept through
    ctx.saveGState()
    for (i, r) in [CGFloat(238), 300, 362].enumerated() {
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.46 - CGFloat(i) * 0.13))
        ctx.setLineWidth(26 - CGFloat(i) * 5)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.addArc(center: pose.chest, radius: r,
                   startAngle: -0.62, endAngle: 0.74, clockwise: false)
        ctx.strokePath()
    }
    ctx.restoreGState()

    // --- figure
    let ink = CGColor(gray: 1, alpha: 1)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 34, color: CGColor(gray: 0, alpha: 0.30))
    ctx.setStrokeColor(ink)
    ctx.setFillColor(ink)

    limb(ctx, [pose.neck, pose.chest, pose.hip], width: 62)                       // spine
    limb(ctx, [pose.chest, pose.armAElbow, pose.armAHand], width: 48)             // raised arm
    limb(ctx, [pose.chest, pose.armBElbow, pose.armBHand], width: 48)             // trailing arm
    limb(ctx, [pose.hip, pose.legAKnee, pose.legAFoot], width: 54)                // planted leg
    limb(ctx, [pose.hip, pose.legBKnee, pose.legBFoot], width: 54)                // kicked leg

    ctx.fillEllipse(in: CGRect(x: pose.head.x - pose.headR, y: pose.head.y - pose.headR,
                               width: pose.headR * 2, height: pose.headR * 2))
    ctx.restoreGState()

    _ = full
}

// MARK: - Output

func render(_ variant: Variant, to url: URL) {
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    drawIcon(ctx, variant: variant)
    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
    print(String(format: "  %-24s %6.0f KB", (url.lastPathComponent as NSString).utf8String!, Double(png.count) / 1024))
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
render(.light,  to: out.appendingPathComponent("icon_light.png"))
render(.dark,   to: out.appendingPathComponent("icon_dark.png"))
render(.tinted, to: out.appendingPathComponent("icon_tinted.png"))
