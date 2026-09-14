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

    /// Card aspect (width / height): the shape the grid shows, and what the camera has to fit the
    /// pose into.
    private static var aspect: Float { Float(size.width / size.height) }

    /// How many moments of a take are auditioned before one is drawn.
    private static let signatureSamples = 18

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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        // Versioned, and the previous version is deleted: both the framing and the choice of frame
        // changed, so every image the old rules cached is wrong. Without this a device that has
        // run the app before keeps serving exactly the cards this set out to replace.
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("card_art", isDirectory: true))
        let d = caches.appendingPathComponent("card_art_v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    // MARK: - Public API

    /// Memory hits are safe to use straight from the main thread: no disk, no queueing.
    func memoryCached(character key: String) -> UIImage? { mem.object(forKey: "char_\(key)" as NSString) }
    func memoryCached(character: String, dance: String, style: Int) -> UIImage? {
        mem.object(forKey: Self.danceKey(character: character, dance: dance, style: style) as NSString)
    }

    /// Card art is per (character, dance), so both belong in the key - and now also per style,
    /// because the style decides the colour of the light the figure is rimmed with.
    private static func danceKey(character: String, dance: String, style: Int) -> String {
        let who = character.isEmpty ? BuiltInAssets.characterId : character
        return "dance_\(who)__\(dance)__s\(((style % 5) + 5) % 5)"
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
            // The controller is shared with the dance path, which leaves both a pose and a camera
            // behind it. Put the character back on its feet and re-aim before drawing.
            self.controller.resetToRestPose()
            // A character card has no coloured backdrop to match, so the rim goes back to white.
            self.controller.setRimTint(nil)
            self.controller.frameCameraOnPose(aspect: Self.aspect)
            return self.snapshot()
        }
    }

    /// Dance card: `character` striking that dance's signature pose, lit in the style's accent.
    func danceCard(character: String, dance: String, style: Int) async -> UIImage? {
        let who = character.isEmpty ? BuiltInAssets.characterId : character
        let dk = Self.danceKey(character: who, dance: dance, style: style)
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
            guard let self, self.ensureModel(at: modelURL, id: who),
                  let root = self.controller.characterRoot,
                  let clip = VRMAnimationClip.load(clipURL) else { return nil }
            // Reset first: otherwise the rest pose sampled here is the previous dance's pose and
            // every card after the first drifts further out of shape.
            self.controller.resetToRestPose()
            let time = self.signatureTime(clip: clip, root: root)

            // A fresh player for the frame that actually gets drawn. `apply()` carries a foot
            // planting offset from one call to the next, and the audition above left the scout's
            // accumulated on the skeleton.
            self.controller.resetToRestPose()
            // Rimmed in the same colour the backdrop behind this card glows with.
            self.controller.setRimTint(CardBackdrop.accentUIColor(for: style))
            guard let player = self.makePlayer(clip: clip, root: root) else { return nil }
            // One apply. The pose comes straight out of the take's keys, so there is nothing to
            // converge - the twelve rounds this used to run were `PoseRetargeter`'s smoothing
            // settling. No ground is handed over either: an offscreen render has no floor to
            // plant against.
            player.apply(at: time)
            // Only now is there a pose to frame. Doing this at install time - which is what
            // `setupFrontCamera()` does - aims at a standing character that the take has since
            // thrown somewhere else entirely.
            self.controller.frameCameraOnPose(aspect: Self.aspect)
            return self.snapshot()
        }
    }

    // MARK: - Choosing the frame

    private func makePlayer(clip: VRMAnimationClip, root: SCNNode) -> VRMAnimationPlayer? {
        VRMAnimationPlayer(clip: clip, root: root, bone: { [weak self] name in
            self?.controller.humanoidNode(name)
        })
    }

    /// Which moment of a take the card poses on.
    ///
    /// This used to be a flat 45% of the take, for every dance. That is a lottery, and the cards
    /// showed it: on a two-second clip 45% lands mid-transition, and the grid held a picture of a
    /// shin, a handstand cropped at the waist, and one card whose dancer had travelled out of shot
    /// entirely. Audition the take and keep the most readable moment instead.
    ///
    /// Cheap enough to do per card: each sample writes bone rotations and measures a handful of
    /// joints, with nothing rendered until a winner is picked.
    private func signatureTime(clip: VRMAnimationClip, root: SCNNode) -> Float {
        let fallback = clip.duration * 0.45
        guard clip.duration > 0, let scout = makePlayer(clip: clip, root: root) else { return fallback }

        var bestTime = fallback
        var bestScore = -Float.greatestFiniteMagnitude
        for i in 0..<Self.signatureSamples {
            // Stay off both ends: takes open and close on the neutral stance they were exported
            // from, and a card of someone standing still sells nothing.
            let f = 0.18 + 0.64 * Float(i) / Float(Self.signatureSamples - 1)
            let t = clip.duration * f
            scout.apply(at: t)
            let score = poseScore()
            if score > bestScore {
                bestScore = score
                bestTime = t
            }
        }
        return bestTime
    }

    /// How well the pose currently on the skeleton reads as a card. Everything is measured against
    /// the model's own height, so scores are comparable across characters.
    private func poseScore() -> Float {
        let bones = controller.boneNodes
        let scheme = controller.scheme
        func at(_ name: String) -> simd_float3? { bones[name]?.simdWorldPosition }

        guard let hips = at(scheme.hips), let head = at(scheme.head),
              let leftShoulder = at(scheme.leftShoulder),
              let rightShoulder = at(scheme.rightShoulder) else { return -.greatestFiniteMagnitude }
        let height = max(controller.modelHeight, 0.001)

        // Limbs thrown clear of the body: the difference between a silhouette and a person
        // standing there.
        let hands = [scheme.leftHand, scheme.rightHand].compactMap(at)
        let limbs = hands + [scheme.leftFoot, scheme.rightFoot].compactMap(at)
        let openness = limbs.isEmpty ? 0
            : limbs.reduce(Float(0)) { $0 + simd_length($1 - hips) } / Float(limbs.count) / height

        // Squared to the lens. `normalizeOrientation()` lands the character's left shoulder on +X
        // and its forward on +Z, so a pose facing the camera has a wide shoulder span in X, and the
        // same cross product that function uses comes back pointing at the camera.
        let span = leftShoulder - rightShoulder
        let shoulders = abs(span.x) / height
        var facing: Float = 0
        if simd_length_squared(span) > 1e-8 {
            facing = simd_cross(simd_normalize(span), simd_float3(0, 1, 0)).z
        }

        // A card of someone's palm across their own face is a wasted card.
        var facePenalty: Float = 0
        for hand in hands {
            let d = simd_length(hand - head) / height
            if d < 0.13 { facePenalty += (0.13 - d) * 4 }
        }

        // Upright, but only as a nudge. A handstand makes a fine card now that the camera follows
        // the pose; it just should not beat a readable one by accident.
        let upright = (head.y - hips.y) / height

        return openness + shoulders * 0.9 + upright * 0.4 + max(0, facing) * 0.4 - facePenalty
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
            // Off, deliberately. This adds a white omni that follows the camera, on top of the four
            // lights `addLights()` already built - and a frontal fill with no direction to it flattens
            // every shading cue the rig produces. It is why the figures came out as evenly bright
            // stickers with no terminator and no silhouette, against a backdrop drawn as a dark stage.
            r.autoenablesDefaultLighting = false
            renderer = r
        }
        r.scene = controller.scene
        r.pointOfView = cam
        return r.snapshot(atTime: 0, with: Self.size, antialiasingMode: DeviceTier.thumbAntialiasing)
    }
}
