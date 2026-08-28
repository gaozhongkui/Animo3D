//
//  USDZOpacityFixer.swift
//  Animo3D
//
//  Fixes the "translucent / washed out" look of Sketchfab's auto-generated USDZ files in AR Quick Look:
//  such models often use the specular-glossiness workflow and wire opacity to the texture alpha,
//  which Apple's Quick Look (metallic-roughness) renders as translucent.
//  The approach: load with SceneKit -> force every material opaque -> re-export as a new USDZ.
//  The re-export also normalizes materials into a Quick Look friendly form. It only runs when transparency is detected, so normal models are untouched.
//

import Foundation
import SceneKit

enum USDZOpacityFixer {
    /// If the model contains transparent materials, forces them opaque and re-exports, returning the new file; otherwise returns the input unchanged.
    /// The result is cached as `<original name>.opaque.usdz`. Call on a background thread (it does disk IO and an export).
    ///
    /// WARNING: the re-export loads the entire textured model into memory and re-encodes it, which is a large memory spike.
    /// On low-memory devices (such as the 3GB iPhone X) that step combined with AR blows past the limit and **reboots the device**,
    /// so low-memory devices and oversized files always skip it (slight translucency beats rebooting the phone).
    static func makeOpaqueIfNeeded(_ url: URL) -> URL {
        let ram = ProcessInfo.processInfo.physicalMemory
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        // Skip devices under 4GB; skip files > 20MB (the memory spike is too large and low-memory devices reboot)
        if ram < 4_000_000_000 || fileSize > 20 * 1024 * 1024 {
            NSLog("[Opaque] skipping re-export (low memory or large file) ram=%llu size=%d", ram, fileSize)
            return url
        }

        let out = url.deletingPathExtension().appendingPathExtension("opaque.usdz")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let scene = try? SCNScene(url: url) else { return url }

        var hasTransparency = false
        scene.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { m in
                if m.transparency < 1 || m.transparent.contents != nil { hasTransparency = true }
            }
        }
        guard hasTransparency else { return url }   // Normal models are left untouched, preserving fidelity

        scene.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { m in
                m.transparency = 1
                m.transparent.contents = nil
                m.transparencyMode = .default
                m.writesToDepthBuffer = true
            }
        }
        return scene.write(to: out, options: nil, delegate: nil, progressHandler: nil) ? out : url
    }
}
