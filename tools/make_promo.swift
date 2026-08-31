//
//  make_promo.swift
//  Animo3D / tools
//
//  Builds App Store promotional screenshots from real captures of the running app.
//
//  Each output is a 1290x2796 (6.7") canvas: the brand gradient from the app icon, a headline and
//  subhead, and the actual screenshot below them. Generated rather than hand-composed so the copy
//  and framing can be re-run whenever the UI changes - screenshots go stale faster than anything
//  else in a listing.
//
//  Build & run:
//      swiftc -O tools/make_promo.swift -o /tmp/make_promo
//      /tmp/make_promo [--canvas WxH] <out-dir> <shot.png> <headline> <subhead> [...]
//
//  Defaults to 1290x2796 (iPhone 6.7"). Pass --canvas 2064x2752 for the 13" iPad slot. Type sizes
//  scale with the canvas width and the screenshot is auto-fitted to whatever height the copy leaves,
//  so one layout serves every store size.
//
//  Use \n inside a headline to force a line break.
//

import Foundation
import AppKit
import CoreGraphics

var W: CGFloat = 1290
var H: CGFloat = 2796
/// Everything is authored against a 1290-wide canvas and scaled from there.
var K: CGFloat { W / 1290 }

func gradient(_ ctx: CGContext) {
    // Same ramp as the app icon: violet -> magenta -> warm stage light.
    let colors = [CGColor(red: 0.36, green: 0.20, blue: 0.86, alpha: 1),
                  CGColor(red: 0.72, green: 0.20, blue: 0.72, alpha: 1),
                  CGColor(red: 0.99, green: 0.44, blue: 0.36, alpha: 1)]
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors as CFArray, locations: [0, 0.55, 1]) else { return }
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
}

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func paragraph(_ font: NSFont) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineSpacing = font.pointSize * 0.12
    return style
}

func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, ctx: CGContext) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: color, .paragraphStyle: paragraph(font)
    ]
    ctx.saveGState()
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()
}

func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
    let s = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph(font)])
    return ceil(s.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin]).height)
}

func compose(shot url: URL, headline: String, subhead: String, to out: URL) -> Bool {
    guard let src = NSImage(contentsOf: url),
          let shot = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("  ! cannot read \(url.lastPathComponent)\n".data(using: .utf8)!)
        return false
    }
    guard let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setShouldAntialias(true)
    gradient(ctx)

    // --- copy
    let margin = 96 * K
    let textW = W - margin * 2
    let headFont = NSFont.systemFont(ofSize: 92 * K, weight: .heavy)
    let subFont = NSFont.systemFont(ofSize: 40 * K, weight: .medium)
    let headH = height(of: headline, font: headFont, width: textW)
    let subH = height(of: subhead, font: subFont, width: textW)

    let headTop = 132 * K
    draw(headline, font: headFont, color: .white,
         in: CGRect(x: margin, y: headTop, width: textW, height: headH + 20 * K), ctx: ctx)
    draw(subhead, font: subFont, color: NSColor.white.withAlphaComponent(0.82),
         in: CGRect(x: margin, y: headTop + headH + 30 * K, width: textW, height: subH + 20 * K), ctx: ctx)

    // --- device screen, auto-fitted to whatever height the copy left behind
    let top = headTop + headH + 30 * K + subH + 90 * K
    let shotAspect = CGFloat(shot.height) / CGFloat(shot.width)
    let available = H - top - H * 0.06
    let deviceW = min(W - margin * 2 - 60 * K, available / shotAspect)
    let deviceH = deviceW * shotAspect
    // CG origin is bottom-left; `top` is measured from the top of the canvas.
    let frame = CGRect(x: (W - deviceW) / 2, y: H - top - deviceH, width: deviceW, height: deviceH)
    let radius = deviceW * 0.085

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26 * K), blur: 60 * K, color: CGColor(gray: 0, alpha: 0.42))
    ctx.addPath(roundedPath(frame, radius))
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(roundedPath(frame, radius))
    ctx.clip()
    ctx.draw(shot, in: frame)
    ctx.restoreGState()

    // hairline edge so the screen reads as a device against a bright background
    ctx.addPath(roundedPath(frame, radius))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
    ctx.setLineWidth(3 * K)
    ctx.strokePath()

    guard let img = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    try? png.write(to: out)
    print(String(format: "  %-16s %6.0f KB", (out.lastPathComponent as NSString).utf8String!,
                 Double(png.count) / 1024))
    return true
}

var args = CommandLine.arguments
if args.count > 2, args[1] == "--canvas" {
    let parts = args[2].split(separator: "x").compactMap { Double($0) }
    guard parts.count == 2 else { print("bad --canvas, expected WxH"); exit(2) }
    W = CGFloat(parts[0]); H = CGFloat(parts[1])
    args.removeSubrange(1...2)
}
guard args.count >= 5, (args.count - 2) % 3 == 0 else {
    print("usage: make_promo [--canvas WxH] <out-dir> <shot.png> <headline> <subhead> [...]")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var i = 2, n = 1, failures = 0
while i + 2 < args.count {
    let shot = URL(fileURLWithPath: args[i])
    let headline = args[i + 1].replacingOccurrences(of: "\\n", with: "\n")
    if !compose(shot: shot, headline: headline, subhead: args[i + 2],
                to: outDir.appendingPathComponent(String(format: "promo_%d.png", n))) { failures += 1 }
    i += 3; n += 1
}
exit(failures > 0 ? 1 : 0)
