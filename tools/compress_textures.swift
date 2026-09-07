//
//  compress_textures.swift
//  Animo3D / tools
//
//  Shrinks a .scn by re-encoding the textures embedded in it (macOS command line).
//
//  Why: the character models are 93% texture. Remy is 58MB, of which 54MB is 21 maps stored as
//  uncompressed PNG - one of them 6MB - while its mesh is only 19k vertices. Erika is 40MB with 33MB
//  of maps. Nothing about a character dancing at phone size needs 4096-wide PNGs, and Supabase's
//  free tier refuses a single file over 50MB, so Remy could not even be uploaded.
//
//  What it does: decode each map, downscale so the longest edge is at most --max-edge, re-encode as
//  JPEG at --quality, and write the scene back out. Maps with an alpha channel keep PNG (JPEG has no
//  alpha, and a cutout texture re-encoded as JPEG turns its transparent regions opaque).
//
//  Normal maps are given their own, higher quality: JPEG chroma artifacts in a normal map read as
//  bumpy shading across a smooth surface, which is far more visible than the same artifacts in a
//  colour map.
//
//  Build & run:
//      swiftc -O tools/compress_textures.swift -o /tmp/compress_textures
//      /tmp/compress_textures <out-dir> <model.scn> [more models...] [--max-edge 1024] [--quality 0.85]
//

import Foundation
import SceneKit
import AppKit
import CoreGraphics

struct Options {
    var maxEdge = 1024
    var quality: CGFloat = 0.85
    /// Normal maps carry geometry, not colour: artifacts there show up as fake bumps.
    var normalQuality: CGFloat = 0.95
    /// Lower bound applied to roughness maps, 0 to leave them alone.
    ///
    /// `sanitizeMaterials` clamps roughness to 0.45 - but only when it is a scalar. Remy, Erika and
    /// The Boss drive roughness from a *texture*, so the clamp never ran on them, and those maps are
    /// authored at 0.20-0.32 (measured means of 50-82 out of 255). Under the stage key light that
    /// reads as wet plastic. The floor cannot be applied at runtime without re-uploading the texture
    /// every load, so it is baked in here.
    var roughnessFloor: Double = 0.45
}

/// Every texture slot a material can hold. `metalness` is included even though the app forces it to
/// zero at load - the file still carries the map, and it still costs bytes.
func slots(_ m: SCNMaterial) -> [(String, SCNMaterialProperty)] {
    [("diffuse", m.diffuse), ("normal", m.normal), ("metalness", m.metalness),
     ("roughness", m.roughness), ("emission", m.emission), ("specular", m.specular),
     ("ambientOcclusion", m.ambientOcclusion), ("selfIllumination", m.selfIllumination),
     ("displacement", m.displacement), ("transparent", m.transparent)]
}

/// Already-compressed maps are left alone, so the tool is idempotent. Without this, a second run
/// re-encodes JPEG as JPEG and each pass loses a little more - and this runs in place on the source
/// assets, so a second pass is a matter of when, not if.
func alreadyCompressed(_ contents: Any?, maxEdge: Int) -> Bool {
    guard let data = contents as? Data, data.count > 3 else { return false }
    let isJPEG = data[data.startIndex] == 0xFF && data[data.startIndex + 1] == 0xD8
    guard isJPEG, let rep = NSBitmapImageRep(data: data) else { return false }
    return max(rep.pixelsWide, rep.pixelsHigh) <= maxEdge
}

func decode(_ contents: Any?) -> CGImage? {
    if let data = contents as? Data {
        return NSBitmapImageRep(data: data)?.cgImage
    }
    if CFGetTypeID(contents as CFTypeRef) == CGImage.typeID { return (contents as! CGImage) }
    if let img = contents as? NSImage {
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    return nil
}

/// Only two slots can legitimately be a cutout. A normal or roughness map is data in RGB; the alpha
/// channel these files carry is a leftover from the exporter, and keeping it forces PNG for no
/// reason - which is what left every map at PNG size on the first pass.
let alphaCapableSlots: Set<String> = ["diffuse", "transparent"]

/// Whether the alpha channel actually does anything. Mixamo's PNGs are RGBA whether or not the
/// texture has a single transparent pixel, so the declared channel is not the question - the pixels
/// are. A fully opaque map re-encodes as JPEG and drops roughly 8x.
func hasMeaningfulAlpha(_ img: CGImage) -> Bool {
    switch img.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: break
    }
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return true }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Anything below 250 counts: a handful of 254s is dithering, a real cutout has large 0 regions.
    var belowThreshold = 0
    for i in stride(from: 3, to: buf.count, by: 4) where buf[i] < 250 { belowThreshold += 1 }
    return Double(belowThreshold) / Double(w * h) > 0.001
}

func resize(_ img: CGImage, maxEdge: Int) -> CGImage? {
    let longest = max(img.width, img.height)
    guard longest > maxEdge else { return img }
    let scale = Double(maxEdge) / Double(longest)
    let w = max(1, Int((Double(img.width) * scale).rounded()))
    let h = max(1, Int((Double(img.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// Raise every channel of a roughness map to at least `floor`. Values above it keep the spread the
/// artist authored - eyes stay glossier than leather - so this only removes the mirror end.
func applyRoughnessFloor(_ img: CGImage, floor: Double) -> CGImage? {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let min8 = UInt8(max(0, min(255, floor * 255)))
    for i in stride(from: 0, to: buf.count, by: 4) {
        if buf[i]   < min8 { buf[i]   = min8 }
        if buf[i+1] < min8 { buf[i+1] = min8 }
        if buf[i+2] < min8 { buf[i+2] = min8 }
    }
    return ctx.makeImage()
}

func encode(_ img: CGImage, keepAlpha: Bool, quality: CGFloat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: img)
    if keepAlpha { return rep.representation(using: .png, properties: [:]) }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
}

func compress(_ url: URL, to outURL: URL, _ opt: Options) -> Bool {
    guard let scene = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
        FileHandle.standardError.write("  ! cannot open \(url.lastPathComponent)\n".data(using: .utf8)!)
        return false
    }

    var before = 0, after = 0, touched = 0, skipped = 0
    var seen = Set<ObjectIdentifier>()

    scene.rootNode.enumerateHierarchy { node, _ in
        guard let g = node.geometry else { return }
        for m in g.materials {
            // The same material object is often shared by several geometries.
            guard seen.insert(ObjectIdentifier(m)).inserted else { continue }
            for (label, prop) in slots(m) {
                guard let contents = prop.contents else { continue }
                if label != "roughness", alreadyCompressed(contents, maxEdge: opt.maxEdge) {
                    let n = (contents as? Data)?.count ?? 0
                    before += n; after += n; skipped += 1; continue
                }
                let originalBytes = (contents as? Data)?.count ?? 0
                guard let img = decode(contents) else { continue }
                let alpha = alphaCapableSlots.contains(label) && hasMeaningfulAlpha(img)
                guard var scaled = resize(img, maxEdge: opt.maxEdge) else { continue }
                if label == "roughness", opt.roughnessFloor > 0,
                   let floored = applyRoughnessFloor(scaled, floor: opt.roughnessFloor) {
                    scaled = floored
                }
                let q = label == "normal" ? opt.normalQuality : opt.quality
                guard let data = encode(scaled, keepAlpha: alpha, quality: q) else { continue }
                // Never make a map bigger than it already was.
                guard originalBytes == 0 || data.count < originalBytes else {
                    before += originalBytes; after += originalBytes; continue
                }
                prop.contents = data
                before += originalBytes
                after += data.count
                touched += 1
                print(String(format: "    %-18s %4d x %-4d -> %4d x %-4d  %7.0f KB -> %6.0f KB%@",
                             (label as NSString).utf8String!, img.width, img.height,
                             scaled.width, scaled.height,
                             Double(originalBytes) / 1024, Double(data.count) / 1024,
                             (alpha ? " (png, alpha)" : "") as NSString as String))
            }
        }
    }

    guard scene.write(to: outURL, options: nil, delegate: nil, progressHandler: nil) else {
        FileHandle.standardError.write("  ! cannot write \(outURL.lastPathComponent)\n".data(using: .utf8)!)
        return false
    }
    func fileSize(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
    }
    let inSize = fileSize(url), outSize = fileSize(outURL)
    print(String(format: "  %@: %d maps re-encoded, %d already compressed, textures %.1f -> %.1f MB, file %.1f -> %.1f MB (%.0f%% smaller)",
                 url.deletingPathExtension().lastPathComponent as NSString as String,
                 touched, skipped, Double(before) / 1e6, Double(after) / 1e6,
                 Double(inSize) / 1e6, Double(outSize) / 1e6,
                 (1 - Double(outSize) / Double(max(inSize, 1))) * 100))
    return true
}

func run() {
        var opt = Options()
        var positional: [String] = []
        var i = 1
        let args = CommandLine.arguments
        while i < args.count {
            switch args[i] {
            case "--max-edge": i += 1; opt.maxEdge = Int(args[i]) ?? opt.maxEdge
            case "--quality": i += 1; opt.quality = CGFloat(Double(args[i]) ?? 0.85)
            case "--normal-quality": i += 1; opt.normalQuality = CGFloat(Double(args[i]) ?? 0.95)
            case "--roughness-floor": i += 1; opt.roughnessFloor = Double(args[i]) ?? 0.45
            default: positional.append(args[i])
            }
            i += 1
        }
        guard positional.count >= 2 else {
            print("usage: compress_textures <out-dir> <model.scn> [model...] [--max-edge N] [--quality Q]")
            exit(2)
        }
        let outDir = URL(fileURLWithPath: positional[0])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("max-edge=\(opt.maxEdge) quality=\(opt.quality) normal-quality=\(opt.normalQuality)")

        var failures = 0
        for path in positional.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let out = outDir.appendingPathComponent(url.lastPathComponent)
            if !compress(url, to: out, opt) { failures += 1 }
        }
        exit(failures > 0 ? 1 : 0)
}

run()
