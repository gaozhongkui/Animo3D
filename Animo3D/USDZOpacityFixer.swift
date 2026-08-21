//
//  USDZOpacityFixer.swift
//  Animo3D
//
//  修复 Sketchfab 自动生成的 USDZ 在 AR Quick Look 里"半透明/发虚"的问题：
//  这类模型常用 specular-glossiness 工作流、且把 opacity 连到贴图 alpha，
//  苹果的 Quick Look(metallic-roughness)会把它渲染成半透明。
//  做法：用 SceneKit 加载 → 把所有材质强制不透明 → 重导出成新的 USDZ。
//  重导出同时把材质归一成 Quick Look 友好的形式。仅当检测到透明时才处理，避免影响正常模型。
//

import Foundation
import SceneKit

enum USDZOpacityFixer {
    /// 若模型含透明材质，则强制不透明并重导出，返回新文件；否则原样返回。
    /// 结果按 `<原名>.opaque.usdz` 缓存。应在后台线程调用（含磁盘 IO 与导出）。
    ///
    /// ⚠️ 重导出会把整只带贴图模型在内存里加载+重新编码，是个很大的内存尖峰。
    /// 在低内存设备（如 iPhone X 3GB）上，这一步叠加 AR 会把内存顶爆导致**设备重启**，
    /// 所以低内存设备 / 超大文件一律跳过（宁可略微半透明，也不能让手机重启）。
    static func makeOpaqueIfNeeded(_ url: URL) -> URL {
        let ram = ProcessInfo.processInfo.physicalMemory
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        // 4GB 以下设备跳过；文件 > 20MB 跳过（内存尖峰太大，低内存机会重启）
        if ram < 4_000_000_000 || fileSize > 20 * 1024 * 1024 {
            NSLog("[Opaque] 跳过重导出（低内存或大文件）ram=%llu size=%d", ram, fileSize)
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
        guard hasTransparency else { return url }   // 正常模型不动，保真

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
