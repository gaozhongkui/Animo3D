//
//  ThumbRenderer.swift
//  Animo3D
//
//  Offscreen thumbnail rendering hub: a single global, serial pipeline reusing one scene controller and one Metal renderer.
//
//  Why this exists:
//  Every card (CharacterThumbView / DanceThumbView) used to spin up its own `Task.detached`,
//  create a CharacterSceneController inside it and **fully load the model** (4-60MB).
//  The dance list holds 44 dances, so fast scrolling had a dozen loads in flight at once, each keeping a full copy of the model:
//  memory spiked, disk IO and GPU contention piled up, and the list froze. On top of that, cancelling `.task` does not cancel
//  `Task.detached`, so the work kept running after the card had scrolled away.
//
//  Once the models moved to the CDN a second problem appeared: rendering a card meant *downloading*
//  a model first, so the nine-character home grid needed 191MB before it could show anything, and
//  the dance grid needed a 750KB mocap clip per card. Both grids simply span forever.
//  So the picture is now looked for in this order:
//
//      memory -> pre-rendered PNG (bundled, then catalog) -> disk cache -> offscreen render
//
//  Pre-rendered art is ~40KB per card and comes from `tools/render_thumbs.swift`, which mirrors the
//  framing below. The offscreen renderer stays as the fallback for anything without art (a
//  user-generated character, a new dance) and is the only path that needs the model itself.
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
        if let m = mem.object(forKey: ck as NSString) { return m }

        let item = RemoteAssets.shared.character(key)
        if let art = await preRendered(cacheKey: ck, bundledName: "thumb_\(key)", remote: item?.thumb) {
            return art
        }
        if let disk = await diskCached(key: ck, file: dirs.char.appendingPathComponent(ck + ".png")) { return disk }

        // No art anywhere: fall back to rendering, which needs the model itself.
        guard let modelURL = try? await RemoteAssets.shared.resolveCharacterModel(key) else {
            NSLog("[Thumb] no art and no model for character %@", key)
            return nil
        }
        return await rendered(key: ck, file: dirs.char.appendingPathComponent(ck + ".png")) { [weak self] in
            guard let self, self.ensureModel(at: modelURL, id: key, portrait: true) else { return nil }
            return self.snapshot()
        }
    }

    /// Dance pose thumbnail: the character striking that dance's signature frame. `model` includes the extension.
    func danceImage(model: String, dance: String) async -> UIImage? {
        let dk = danceKey(model, dance)
        if let m = mem.object(forKey: dk as NSString) { return m }

        // Dance art is per (character, dance), so there are 9x44 of them - too many to pre-render.
        // The card is rendered on device instead; what makes that cheap is the single-frame `pose`
        // extract below, so a grid of 44 costs ~88KB rather than 21MB of full clips.
        let item = RemoteAssets.shared.dance(dance)
        if let disk = await diskCached(key: dk, file: dirs.dance.appendingPathComponent(dk + ".png")) { return disk }

        // Rendering needs the model and one pose. Only mixamo data works here: the pose is applied
        // through PoseRetargeter, which reads world-space joint positions.
        guard let modelURL = try? await RemoteAssets.shared.resolve(url: model) else { return nil }
        let clipRef = item?.pose ?? item?.clip(rig: "mixamo") ?? AssetRef(url: "mocap_\(dance).json")
        let clipURL = try? await RemoteAssets.shared.resolve(clipRef)

        return await rendered(key: dk, file: dirs.dance.appendingPathComponent(dk + ".png")) { [weak self] in
            guard let self, self.ensureModel(at: modelURL, id: model, portrait: false) else { return nil }
            self.controller.resetToRestPose()   // Reset, otherwise the previous dance's pose gets sampled as the rest pose
            if let clipURL, let clip = MocapClip.load(clipURL), !clip.frames.isEmpty {
                // The retargeter smooths over time, so apply the same frame repeatedly until it converges.
                // A `pose` file holds exactly that frame already; a full clip is sampled 45% in.
                let rt = PoseRetargeter(controller: self.controller)
                let idx = clip.frames.count == 1 ? 0 : Int(Double(clip.frames.count) * 0.45)
                for _ in 0..<12 { rt.apply(world: clip.frames[min(idx, clip.frames.count - 1)]) }
            }
            return self.snapshot()
        }
    }

    // MARK: - Pre-rendered art

    /// Card art produced offline by `tools/render_thumbs.swift`: bundled copy first, then the
    /// catalog's remote copy (~40KB, versus megabytes for the model it was rendered from).
    private func preRendered(cacheKey: String, bundledName: String, remote: AssetRef?) async -> UIImage? {
        if let url = Bundle.main.url(forResource: bundledName, withExtension: "png"),
           let img = await decode(url) {
            mem.setObject(img, forKey: cacheKey as NSString)
            return img
        }
        guard let remote else { return nil }
        if let local = RemoteAssets.shared.localURL(for: remote.file), let img = await decode(local) {
            mem.setObject(img, forKey: cacheKey as NSString)
            return img
        }
        guard let url = try? await RemoteAssets.shared.resolve(remote), let img = await decode(url) else { return nil }
        mem.setObject(img, forKey: cacheKey as NSString)
        return img
    }

    private func decode(_ url: URL) async -> UIImage? {
        await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            ioQ.async { c.resume(returning: UIImage(contentsOfFile: url.path)) }
        }
    }

    // MARK: - Cache tiers

    private func diskCached(key: String, file: URL) async -> UIImage? {
        guard let img = await decode(file) else { return nil }
        mem.setObject(img, forKey: key as NSString)
        return img
    }

    /// Offscreen render, globally serial.
    private func rendered(key: String, file: URL, render: @escaping () -> UIImage?) async -> UIImage? {
        await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
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
    private func ensureModel(at url: URL, id: String, portrait: Bool) -> Bool {
        let key = "\(id)|\(portrait)"
        if loadedKey == key && controller.isLoaded { return true }
        loadedKey = ""
        controller.portraitMode = portrait     // Must come before install: the A-pose is applied at mount time
        guard let scene = CharacterSceneController.loadSceneFile(at: url) else { return false }
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
