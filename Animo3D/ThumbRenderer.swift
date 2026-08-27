//
//  ThumbRenderer.swift
//  Animo3D
//
//  缩略图离屏渲染中心：全局唯一、串行、复用同一个场景控制器 + Metal 渲染器。
//
//  为什么要有这个东西：
//  以前每张卡片(CharacterThumbView / DanceThumbView)各自 `Task.detached` 里
//  new 一个 CharacterSceneController 并**完整加载一次模型**(10~60MB)。
//  选舞蹈列表有 44 支舞 → 快速滑动时十几个加载同时在飞,每个还各持一份完整模型,
//  内存暴涨 + 磁盘 IO + GPU 抢占 → 列表滑动卡死。而且 `.task` 取消并不会取消
//  `Task.detached`,划走了活儿照跑。
//
//  现在：内存缓存 → 磁盘缓存(并发,不占主线程) → 离屏渲染(全局串行,一份模型复用)。
//

import UIKit
import SceneKit

final class ThumbRenderer {
    static let shared = ThumbRenderer()

    /// 缩略图像素尺寸(卡片实际显示远小于此,留一点余量给 @3x)。
    static let size = CGSize(width: 360, height: 460)

    // 渲染串行:同一时刻只有一张在渲,避免和列表滑动抢 GPU。
    private let renderQ = DispatchQueue(label: "com.animo3d.thumb.render", qos: .utility)
    // 读盘/解码并发:命中磁盘缓存的不该排在长渲染后面等。
    private let ioQ = DispatchQueue(label: "com.animo3d.thumb.io", qos: .userInitiated, attributes: .concurrent)

    private let mem: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    private lazy var device = MTLCreateSystemDefaultDevice()
    private var renderer: SCNRenderer?                     // 只在 renderQ 上访问
    private let controller = CharacterSceneController()     // 只在 renderQ 上访问
    private var loadedKey = ""                              // 控制器里当前装的 "模型|portrait"

    private let dirs: (char: URL, dance: URL) = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let c = base.appendingPathComponent("char_thumbs", isDirectory: true)
        let d = base.appendingPathComponent("dance_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return (c, d)
    }()

    // MARK: - 对外接口

    /// 内存命中(主线程可直接用,不碰磁盘、不排队)。
    func memoryCached(character key: String) -> UIImage? { mem.object(forKey: charKey(key) as NSString) }
    func memoryCached(model: String, dance: String) -> UIImage? { mem.object(forKey: danceKey(model, dance) as NSString) }

    /// 角色缩略图(静态 A-pose)。
    func characterImage(_ key: String) async -> UIImage? {
        let ck = charKey(key)
        return await image(key: ck, file: dirs.char.appendingPathComponent(ck + ".png")) { [weak self] in
            guard let self else { return nil }
            guard self.ensureModel(characterModelFile(key), portrait: true) else { return nil }
            return self.snapshot()
        }
    }

    /// 舞蹈姿势缩略图：角色摆出该支舞的代表帧。model 含扩展名。
    func danceImage(model: String, dance: String) async -> UIImage? {
        let dk = danceKey(model, dance)
        return await image(key: dk, file: dirs.dance.appendingPathComponent(dk + ".png")) { [weak self] in
            guard let self else { return nil }
            guard self.ensureModel(model, portrait: false) else { return nil }
            self.controller.resetToRestPose()   // 复位,否则会把上一支舞的姿势当静止姿态采样
            if let url = Bundle.main.url(forResource: dance, withExtension: "json"),
               let clip = MocapClip.load(url), !clip.frames.isEmpty {
                // 重定向器带平滑,重复应用同一帧使其收敛
                let rt = PoseRetargeter(controller: self.controller)
                let idx = min(clip.frames.count - 1, Int(Double(clip.frames.count) * 0.45))
                for _ in 0..<12 { rt.apply(world: clip.frames[idx]) }
            }
            return self.snapshot()
        }
    }

    // MARK: - 缓存三级流水

    private func image(key: String, file: URL, render: @escaping () -> UIImage?) async -> UIImage? {
        if let m = mem.object(forKey: key as NSString) { return m }
        // 1) 磁盘(并发队列,不阻塞主线程——以前是在 .task 里主线程同步读盘 + 解 PNG)
        if let disk = await withCheckedContinuation({ (c: CheckedContinuation<UIImage?, Never>) in
            ioQ.async { c.resume(returning: UIImage(contentsOfFile: file.path)) }
        }) {
            mem.setObject(disk, forKey: key as NSString)
            return disk
        }
        // 2) 离屏渲染(全局串行)
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            renderQ.async { [weak self] in
                guard let self else { c.resume(returning: nil); return }
                // 排队期间可能已被别的卡片渲好了
                if let m = self.mem.object(forKey: key as NSString) { c.resume(returning: m); return }
                if let disk = UIImage(contentsOfFile: file.path) {
                    self.mem.setObject(disk, forKey: key as NSString)
                    c.resume(returning: disk); return
                }
                let img = render()
                if let img {
                    self.mem.setObject(img, forKey: key as NSString)
                    if let data = img.pngData() { try? data.write(to: file) }
                }
                c.resume(returning: img)
            }
        }
    }

    // MARK: - renderQ 上的实际渲染

    /// 保证控制器里装着指定模型。同一个模型的 N 支舞只加载一次(以前是 N 次)。
    private func ensureModel(_ file: String, portrait: Bool) -> Bool {
        let key = "\(file)|\(portrait)"
        if loadedKey == key && controller.isLoaded { return true }
        loadedKey = ""
        controller.portraitMode = portrait     // 必须在 install 之前:A-pose 是在挂载时摆的
        guard let scene = CharacterSceneController.loadSceneFile(named: file) else { return false }
        controller.install(scene)
        guard controller.isLoaded else { return false }
        controller.scene.background.contents = UIColor.clear
        loadedKey = key
        return true
    }

    private func snapshot() -> UIImage? {
        guard let device, let cam = controller.cameraNode else { return nil }
        let r: SCNRenderer
        if let existing = renderer {
            r = existing
        } else {
            r = SCNRenderer(device: device, options: nil)
            r.autoenablesDefaultLighting = true
            renderer = r
        }
        r.scene = controller.scene
        r.pointOfView = cam
        return r.snapshot(atTime: 0, with: Self.size, antialiasingMode: DeviceTier.thumbAntialiasing)
    }

    // MARK: - key

    private func charKey(_ key: String) -> String { key }
    private func danceKey(_ model: String, _ dance: String) -> String {
        "\(model)__\(dance)".replacingOccurrences(of: ".", with: "_")
    }
}
