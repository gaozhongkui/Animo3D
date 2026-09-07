//
//  ThumbRenderer.swift
//  Animo3D
//
//  Card art. Characters use art pre-rendered offline (memory -> bundle -> catalog -> disk); dances
//  are rendered on device (memory -> disk -> offscreen render).
//
//  Two things keep the dance path from repeating its own history:
//
//    1. **One model load serves all 44 cards.** They render on a single global serial queue against
//        one reused controller, so the selected character's model is parsed once. Every card used to
//        spin up its own controller inside `Task.detached` and parse the model again (4-60MB a
//        time); `.task` cancellation never reached those, so the work kept running after a card had
//        scrolled away, and fast scrolling had a dozen parses in flight.
//    2. **The model is small enough for this to be affordable.** Cards show the character the user
//        picked, which means art is per (character, dance). That was untenable when a model was
//        58MB; after tools/compress_textures.swift the largest is 7.6MB, and the dance step already
//        prewarms that exact file for the stage, so the card grid adds no download of its own.
//
//  The clip a card needs is the same file the stage needs, so fetching it here is a prefetch rather
//  than a cost: by the time the user presses Start it is already cached.
//

import UIKit
import SceneKit

final class ThumbRenderer {
    static let shared = ThumbRenderer()

    /// Thumbnail pixel size (cards display much smaller than this; the headroom is for @3x).
    static let size = CGSize(width: 360, height: 460)

    /// The frame of a take a card poses on, matching tools/render_thumbs.swift.
    private static let signatureFrame = 0.45

    // Rendering is serial: only one thumbnail renders at a time, so it never fights the list scroll.
    private let renderQ = DispatchQueue(label: "com.animo3d.thumb.render", qos: .utility)
    // Disk reads and decodes are concurrent: a cache hit should not queue behind a long render.
    private let ioQ = DispatchQueue(label: "com.animo3d.thumb.io", qos: .userInitiated, attributes: .concurrent)

    private let mem: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 120
        return c
    }()

    private lazy var device = MTLCreateSystemDefaultDevice()
    private var renderer: SCNRenderer?                      // renderQ only
    private let controller = CharacterSceneController()      // renderQ only
    private var loadedKey = ""                               // model currently in the controller

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("card_art", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // MARK: - Public API

    /// Memory hits are safe to use straight from the main thread: no disk, no queueing.
    func memoryCached(character key: String) -> UIImage? { mem.object(forKey: "char_\(key)" as NSString) }
    func memoryCached(character: String, dance: String) -> UIImage? {
        mem.object(forKey: Self.danceKey(character: character, dance: dance) as NSString)
    }

    /// Card art is per (character, dance), so both belong in the key.
    private static func danceKey(character: String, dance: String) -> String {
        let who = character.isEmpty ? BuiltInAssets.characterId : character
        return "dance_\(who)__\(dance)"
    }

    /// Character card (static rest pose).
    func characterImage(_ key: String) async -> UIImage? {
        let ck = "char_\(key)"
        if let m = mem.object(forKey: ck as NSString) { return m }
        if let art = await art(cacheKey: ck, bundled: "thumb_\(key)", remote: RemoteAssets.shared.character(key)?.thumb) {
            return art
        }
        if let disk = await diskCached(key: ck) { return disk }

        // No art anywhere: render, which is the only path that needs the model itself.
        guard let modelURL = try? await RemoteAssets.shared.resolveCharacterModel(key) else {
            NSLog("[Card] no art and no model for character %@", key)
            return nil
        }
        return await rendered(key: ck) { [weak self] in
            guard let self, self.ensureModel(at: modelURL, id: key) else { return nil }
            return self.snapshot()
        }
    }

    /// Dance card: `character` striking that dance's signature pose.
    func danceCard(character: String, dance: String) async -> UIImage? {
        let who = character.isEmpty ? BuiltInAssets.characterId : character
        let dk = Self.danceKey(character: who, dance: dance)
        if let m = mem.object(forKey: dk as NSString) { return m }
        if let disk = await diskCached(key: dk) { return disk }

        guard !who.isEmpty,
              let modelURL = try? await RemoteAssets.shared.resolveCharacterModel(who),
              let clipPath = RemoteAssets.shared.dance(dance)?.clip,
              let clipURL = try? await RemoteAssets.shared.resolve(clipPath) else {
            NSLog("[Card] cannot render %@ for %@", dance, who)
            return nil
        }
        return await rendered(key: dk) { [weak self] in
            guard let self, self.ensureModel(at: modelURL, id: who) else { return nil }
            // Reset first: otherwise PoseRetargeter samples the previous dance's pose as the rest
            // pose and every card after the first drifts further out of shape.
            self.controller.resetToRestPose()
            guard let clip = MocapClip.load(clipURL), !clip.frames.isEmpty else { return nil }
            // The retargeter smooths over time, so the same frame is applied until it converges.
            let rt = PoseRetargeter(controller: self.controller)
            let idx = min(Int(Double(clip.frames.count) * Self.signatureFrame), clip.frames.count - 1)
            for _ in 0..<12 { rt.apply(world: clip.frames[idx]) }
            return self.snapshot()
        }
    }

    // MARK: - Art tiers

    /// Pre-rendered art: the bundled copy first, then the catalog's (~40KB, versus megabytes for
    /// the model it was rendered from).
    private func art(cacheKey: String, bundled: String, remote: AssetPath?) async -> UIImage? {
        if let url = Bundle.main.url(forResource: bundled, withExtension: "png"),
           let img = await decode(url) {
            mem.setObject(img, forKey: cacheKey as NSString)
            return img
        }
        guard let remote else { return nil }
        if let local = RemoteAssets.shared.localURL(for: remote.assetName), let img = await decode(local) {
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

    private func file(for key: String) -> URL { dir.appendingPathComponent(key + ".png") }

    private func diskCached(key: String) async -> UIImage? {
        guard let img = await decode(file(for: key)) else { return nil }
        mem.setObject(img, forKey: key as NSString)
        return img
    }

    /// Offscreen render, globally serial.
    private func rendered(key: String, render: @escaping () -> UIImage?) async -> UIImage? {
        let dest = file(for: key)
        return await withCheckedContinuation { (c: CheckedContinuation<UIImage?, Never>) in
            renderQ.async { [weak self] in
                guard let self else { c.resume(returning: nil); return }
                // Another card may have produced it while this one was queued.
                if let m = self.mem.object(forKey: key as NSString) { c.resume(returning: m); return }
                if let disk = UIImage(contentsOfFile: dest.path) {
                    self.mem.setObject(disk, forKey: key as NSString)
                    c.resume(returning: disk); return
                }
                let img = render()
                if let img {
                    self.mem.setObject(img, forKey: key as NSString)
                    if let data = img.pngData() { try? data.write(to: dest) }
                }
                c.resume(returning: img)
            }
        }
    }

    // MARK: - The actual rendering, on renderQ

    /// Keeps the given model mounted. The N dances of one model load it once, not N times.
    private func ensureModel(at url: URL, id: String) -> Bool {
        if loadedKey == id && controller.isLoaded { return true }
        loadedKey = ""
        guard let scene = CharacterSceneController.loadSceneFile(at: url) else { return false }
        controller.install(scene)
        guard controller.isLoaded else { return false }
        controller.scene.background.contents = UIColor.clear
        loadedKey = id
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
}
