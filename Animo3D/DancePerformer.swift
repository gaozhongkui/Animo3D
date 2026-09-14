//
//  DancePerformer.swift
//  Animo3D
//
//  The one place a character is loaded and a dance is driven onto its skeleton.
//
//  There were four copies of this before: the stage (DanceStage), the selected dance card
//  (LiveDanceView), the enlarged preview (PreviewStage) and the thumbnail renderer each loaded a
//  model, built their own retargeter and started their own player. They had drifted apart
//  in every detail that matters - one parsed on the main thread, one forgot `warmUp`, one assumed
//  every model was a `.scn`, one leaked its display link on dismiss - and a fix applied to one of
//  them stayed broken in the other three. Everything that performs a dance goes through here now.
//
//  A take is a `.vrma`: every humanoid bone's rotation, fingers included, retargeted onto whatever
//  is mounted. The mocap JSON it replaced held twelve joint *positions* for `PoseRetargeter` to fit
//  eight limb bones to - no spine chain, no head, no toes, no fingers. `PoseRetargeter` stays
//  regardless: the camera and video screens have no take to play, only landmarks arriving a frame
//  at a time, and fitting those to a skeleton is what it is for.
//
//  Loading is deliberately two-phase: the model (4-60MB) and the clip (0.2-2.3MB) are parsed on a
//  background task and only node mounting happens on the main thread. Doing the parse inline is
//  what used to freeze the screen when entering the stage and on every character switch.
//

import SwiftUI
import SceneKit
import Combine
import simd

@MainActor
final class DancePerformer: ObservableObject {
    let controller = CharacterSceneController()

    /// True once the character is mounted and the scene is worth showing.
    @Published private(set) var isReady = false

    /// Built for every character whether or not a take is playing: the video-drive screen feeds it
    /// MediaPipe landmarks instead of a stored take.
    private var retargeter: PoseRetargeter?
    private var vrmaPlayer: VRMAnimationPlayer?
    /// Kept so the take can be measured after the fact - see `frameCameraOnTake(aspect:)`.
    private var loadedClip: VRMAnimationClip?
    private var loadedCharacter = ""
    private var loadedDance = ""

    /// The model parsed ahead of time, keyed by the character it belongs to.
    private var prewarmKey = ""
    private var prewarmTask: Task<SCNScene?, Never>?

    var isAnimating: Bool { vrmaPlayer != nil }

    /// Who owns this performer, for logs only.
    private let owner: String

    init(owner: String = "?", groundEnabled: Bool = false, contactShadowOnly: Bool = false) {
        self.owner = owner
        controller.groundEnabled = groundEnabled
        controller.contactShadowOnly = contactShadowOnly
        NSLog("[Performer] %@ created", owner)
    }

    deinit { NSLog("[Performer] %@ released", owner) }

    // MARK: - Prewarm

    /// Start parsing a character's model in the background. Cheap to call repeatedly.
    ///
    /// Without this the same file is parsed again on "Start Performance" after the grid already
    /// parsed it, and `SCNScene(url:)` plus `warmUp` on a 60MB model is seconds of work each time.
    func prewarm(character: String) {
        guard !character.isEmpty, character != prewarmKey else { return }
        prewarmKey = character
        prewarmTask?.cancel()
        prewarmTask = Task.detached(priority: .utility) {
            guard let url = try? await RemoteAssets.shared.resolveCharacterModel(character) else { return nil }
            guard !Task.isCancelled else { return nil }
            return CharacterSceneController.loadSceneFile(at: url, warmUp: true)
        }
    }

    /// Pull down the full take. The dance grid only ever needs the pre-rendered card art, so the
    /// clip itself is still missing at the moment the user presses Start.
    func prewarm(dance: String) {
        guard !dance.isEmpty, let path = RemoteAssets.shared.dance(dance)?.clip else { return }
        Task.detached(priority: .utility) { _ = try? await RemoteAssets.shared.resolve(path) }
    }

    // MARK: - Load

    /// Mount `character` and, when a dance is given, start driving it.
    ///
    /// Returns false when the scene could not be assembled, so the caller can drop its loading mask
    /// instead of leaving it up forever.
    @discardableResult
    func load(character: String, dance: String? = nil) async -> Bool {
        guard !character.isEmpty else { return false }
        stop()

        if character != loadedCharacter || !controller.isLoaded {
            guard let scene = await scene(for: character) else { return false }
            // A parsed scene can only be installed once - install() reparents its root node - so
            // the prewarmed copy is consumed here rather than left for a second Start.
            controller.install(scene)
            guard controller.isLoaded else {
                NSLog("[Performer] model %@ mounted with no skeleton", character)
                return false
            }
            loadedCharacter = character
        }
        // The retargeter is built whether or not there is a clip: the video-drive screen feeds it
        // MediaPipe landmarks instead of a stored take, and that used to be a fifth private copy
        // of this same setup.
        let rt = PoseRetargeter(controller: controller)
        rt.resetCapture()
        retargeter = rt
        isReady = true
        loadedDance = ""

        guard let dance, !dance.isEmpty else { return true }
        guard let path = RemoteAssets.shared.dance(dance)?.clip else {
            NSLog("[Performer] %@ is not in the catalog", dance)
            return false
        }
        guard let url = try? await RemoteAssets.shared.resolve(path) else {
            NSLog("[Performer] failed to download/locate clip %@", path)
            return false
        }
        guard await playVRMA(url) else {
            // Whatever is cached under that name does not parse. Drop it so the next attempt
            // re-downloads instead of failing identically on every launch.
            RemoteAssets.shared.evict(path)
            return false
        }
        loadedDance = dance
        NSLog("[Performer] %@: %@ performing %@", owner, character, dance)
        return true
    }

    private func scene(for character: String) async -> SCNScene? {
        if prewarmKey == character, let task = prewarmTask {
            prewarmKey = ""
            prewarmTask = nil
            if let scene = await task.value { return scene }
        }
        prewarmKey = ""
        prewarmTask = nil
        guard let url = try? await RemoteAssets.shared.resolveCharacterModel(character) else {
            NSLog("[Performer] failed to download/locate model for %@", character)
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(at: url, warmUp: true)
        }.value
    }

    // MARK: - Control

    /// Re-sample the static pose after the character is re-mounted (screen <-> AR).
    /// Re-establish the retargeter's reference pose at the character's *current* place in the world.
    ///
    /// Two things have to happen together, and neither works alone:
    ///
    /// - **The skeleton goes back to its bind pose first.** `resetCapture()` re-samples the rest
    ///   reference on the next frame from whatever the bones happen to look like then - and
    ///   mid-dance that is a dancing pose, not a rest pose. Every subsequent frame is then measured
    ///   against a crouch or a lunge, and the character drifts further from the take each time it
    ///   is re-based. `resetToRestPose()` has carried that warning in its doc comment since it was
    ///   written; it had simply never been called.
    /// - **It has to run after the character is placed, not before.** The retargeter pins the hips
    ///   to `charHipsRestWorld + delta`, an absolute world position captured with the rest pose. In
    ///   AR that capture used to happen on attach, while the character was still hidden in front of
    ///   the camera - so once it was anchored to a floor, every frame dragged the skeleton back to
    ///   the pre-placement spot. The container sat on the anchor; the body did not.
    func rebaseRetarget() {
        controller.resetToRestPose()
        retargeter?.resetCapture()
        // The `.vrma` player writes the hips as a position local to their parent, so it needs no
        // re-capture to follow the character to a new anchor. What it does need is the new floor:
        // its sole offsets and the correction built up against the old ground are both stale.
        vrmaPlayer?.rebase()
    }

    /// Drive the skeleton from live pose landmarks (camera or video source).
    ///
    /// The one thing `.vrma` playback does not replace: there is no clip here, only MediaPipe
    /// landmarks arriving a frame at a time, and turning those into bone rotations is what
    /// `PoseRetargeter` is for.
    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }

    /// Always call this when the view goes away: `CADisplayLink(target:)` retains its target, so a
    /// player left running keeps burning CPU after the page is dismissed.
    func stop() {
        controller.endCameraFollow()
        vrmaPlayer?.stop()
        vrmaPlayer = nil
        loadedDance = ""
    }

    /// Ride the camera along with the take, so the dancer fills the frame throughout.
    ///
    /// The alternative, `frameCameraOnTake(aspect:)`, buys a motionless camera by standing far
    /// enough back to hold every pose in the dance - which on a card leaves the dancer small for
    /// the entire take just because one moment of it is big. Opt-in, like that one: the stage has
    /// its own camera and must not be touched.
    ///
    /// - Parameter aspect: width / height of the box the view occupies.
    func followCameraOnTake(aspect: Float) {
        controller.beginCameraFollow(aspect: aspect)
        // `onFrame` fires from the player's own display link, straight after the pose for that
        // frame is written - which is exactly when the bounds are worth measuring.
        vrmaPlayer?.onFrame = { [weak controller] _ in controller?.stepCameraFollow() }
    }

    /// Aim the camera at everything the loaded take does, once, so the dancer stays inside a view
    /// of this shape for the whole dance without the camera ever moving.
    ///
    /// `setupFrontCamera()` frames the character standing still, at install time. A take that
    /// jumps, tips or travels then carries the dancer straight out of a small card - which looked
    /// exactly like playback having failed. Opt-in, because the stage does its own framing.
    ///
    /// - Parameter aspect: width / height of the box the view occupies.
    func frameCameraOnTake(aspect: Float, samples: Int = 16) {
        guard let root = controller.characterRoot, let clip = loadedClip, clip.duration > 0,
              samples > 1 else { return }
        // A scout of its own: `apply()` carries a foot-planting offset between calls, and the
        // player that is currently on screen must not inherit this sweep's.
        guard let scout = VRMAnimationPlayer(clip: clip, root: root, bone: { [weak self] name in
            self?.controller.humanoidNode(name)
        }) else { return }

        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
        var measured = false
        for i in 0..<samples {
            scout.apply(at: clip.duration * Float(i) / Float(samples - 1))
            guard let b = controller.posedBounds() else { continue }
            lo = simd_min(lo, b.min)
            hi = simd_max(hi, b.max)
            measured = true
        }
        guard measured else { return }

        // Hand the skeleton back: the running player re-poses it on its next tick anyway, but it
        // must not be left holding the last sample if that tick is a frame away.
        controller.resetToRestPose()
        controller.frameCamera(on: (lo, hi), aspect: aspect)
    }

    /// Start a `.vrma` take on whatever is already mounted.
    ///
    /// The take is bone rotations keyed by VRM humanoid name, and `controller.humanoidNode(_:)`
    /// says which node each name is - through `MixamoBoneMap` for a bundled character, through the
    /// file's own humanoid table for an imported one. The player re-expresses every rotation
    /// between the take's rest pose and the model's, so rig, scale and build all drop out - which
    /// is why one file drives every character, imported ones included.
    @discardableResult
    func playVRMA(_ url: URL) async -> Bool {
        guard let root = controller.characterRoot else { return false }
        vrmaPlayer?.stop()
        vrmaPlayer = nil
        // The next player reads the skeleton's current pose as the rest it retargets against, so
        // the last take's pose has to come off first - otherwise every switch compounds the one
        // before it. `resetToRestPose()` has carried this warning since it was written for the
        // thumbnail renderer.
        controller.resetToRestPose()

        // Parsing is a megabyte or two of float accessors, off the main thread like every take.
        guard let clip = await Task.detached(priority: .userInitiated,
                                             operation: { VRMAnimationClip.load(url) }).value else {
            NSLog("[Performer] %@ did not parse", url.lastPathComponent)
            return false
        }

        loadedClip = clip
        vrmaPlayer = VRMAnimationPlayer(clip: clip, root: root,
                                        groundY: { [weak controller] in controller?.groundY }) {
            [weak self] name in
            self?.controller.humanoidNode(name)
        }
        vrmaPlayer?.start()
        loadedDance = url.deletingPathExtension().lastPathComponent
        NSLog("[Performer] playing %@", url.lastPathComponent)
        return vrmaPlayer != nil
    }
}
