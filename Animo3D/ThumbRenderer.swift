//
//  ThumbRenderer.swift
//  Animo3D
//
//  Offscreen thumbnail rendering hub: a single global, serial pipeline reusing one scene controller and one Metal renderer.
//
//  Why this exists:
//  Every card (CharacterThumbView / DanceThumbView) used to spin up its own `Task.detached`,
//  create a CharacterSceneController inside it and **fully load the model** (10-60MB).
//  The dance list holds 44 dances, so fast scrolling had a dozen loads in flight at once, each keeping a full copy of the model:
//  memory spiked, disk IO and GPU contention piled up, and the list froze. On top of that, cancelling `.task` does not cancel
//  `Task.detached`, so the work kept running after the card had scrolled away.
//
//  Now: memory cache -> disk cache (concurrent, off the main thread) -> offscreen render (globally serial, one model reused).
//

import UIKit
import SceneKit

final class ThumbRenderer {
    static let shared = ThumbRenderer()

    /// Thumbnail pixel size (cards display much smaller than this; the headroom is for @3x).
    static let size = CGSize(width: 360, height: 460)

    // Rendering is serial: only one thumbnail renders at a time, so it never fights the list scroll for the GPU.
    private let renderQ = DispatchQueue(label: "com.animo3d.thumb.render", qos: .utility)
    // Disk reads and decodes are concurrent: a disk-cache hit should not queue behind a long render.
    private let ioQ = DispatchQueue(label: "com.animo3d.thumb.io", qos: .userInitiated, attributes: .concurrent)

    private let mem: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    private lazy var device = MTLCreateSystemDefaultDevice()
    private var renderer: SCNRenderer?                     // Only accessed on renderQ
    private let controller = CharacterSceneController()     // Only accessed on renderQ
    private var loadedKey = ""                              // The "model|portrait" currently loaded in the controller

    private let dirs: (char: URL, dance: URL) = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let c = base.appendingPathComponent("char_thumbs", isDirectory: true)
        let d = base.appendingPathComponent("dance_thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return (c, d)
    }()

    // MARK: - Public API

    /// Memory-cache hit (safe to use directly on the main thread; no disk access, no queueing).
    func memoryCached(character key: String) -> UIImage? { mem.object(forKey: charKey(key) as NSString) }
    func memoryCached(model: String, dance: String) -> UIImage? { mem.object(forKey: danceKey(model, dance) as NSString) }

    /// Character thumbnail (static A-pose).
    func characterImage(_ key: String) async -> UIImage? {
        let ck = charKey(key)
        return await image(key: ck, file: dirs.char.appendingPathComponent(ck + ".png")) { [weak self] in
            guard let self else { return nil }
            guard self.ensureModel(characterModelFile(key), portrait: true) else { return nil }
            return self.snapshot()
        }
    }

    /// Dance pose thumbnail: the character striking that dance's signature frame. `model` includes the extension.
    func danceImage(model: String, dance: String) async -> UIImage? {
        let dk = danceKey(model, dance)
        return await image(key: dk, file: dirs.dance.appendingPathComponent(dk + ".png")) { [weak self] in
            guard let self else { return nil }
            guard self.ensureModel(model, portrait: false) else { return nil }
            self.controller.resetToRestPose()   // Reset, otherwise the previous dance's pose gets sampled as the rest pose
            if let url = Bundle.main.url(forResource: dance, withExtension: "json"),
               let clip = MocapClip.load(url), !clip.frames.isEmpty {
                // The retargeter smooths over time, so apply the same frame repeatedly until it converges
                let rt = PoseRetargeter(controller: self.controller)
                let idx = min(clip.frames.count - 1, Int(Double(clip.frames.count) * 0.45))
                for _ in 0..<12 { rt.apply(world: clip.frames[idx]) }
            }
            return self.snapshot()
        }
    }

    // MARK: - Three-tier cache pipeline

    private func image(key: String, file: URL, render: @escaping () -> UIImage?) async -> UIImage? {
        if let m = mem.object(forKey: key as NSString) { return m }
        // 1) Disk (concurrent queue, off the main thread - this used to read and decode the PNG synchronously on the main thread inside .task)
        if let disk = await withCheckedContinuation({ (c: CheckedContinuation<UIImage?, Never>) in
            ioQ.async { c.resume(returning: UIImage(contentsOfFile: file.path)) }
        }) {
            mem.setObject(disk, forKey: key as NSString)
            return disk
        }
        // 2) Offscreen render (globally serial)
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            renderQ.async { [weak self] in
                guard let self else { c.resume(returning: nil); return }
                // Another card may have rendered it while we were queued
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

    // MARK: - The actual rendering, on renderQ

    /// Makes sure the controller holds the given model. The N dances of one model now load it once (it used to be N times).
    private func ensureModel(_ file: String, portrait: Bool) -> Bool {
        let key = "\(file)|\(portrait)"
        if loadedKey == key && controller.isLoaded { return true }
        loadedKey = ""
        controller.portraitMode = portrait     // Must come before install: the A-pose is applied at mount time
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
