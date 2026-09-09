//
//  DancePerformer.swift
//  Animo3D
//
//  The one place a character is loaded and a dance is driven onto its skeleton.
//
//  There were four copies of this before: the stage (DanceStage), the selected dance card
//  (LiveDanceView), the enlarged preview (PreviewStage) and the thumbnail renderer each loaded a
//  model, built their own PoseRetargeter and started their own MocapPlayer. They had drifted apart
//  in every detail that matters - one parsed on the main thread, one forgot `warmUp`, one assumed
//  every model was a `.scn`, one leaked its display link on dismiss - and a fix applied to one of
//  them stayed broken in the other three. Everything that performs a dance goes through here now.
//
//  Loading is deliberately two-phase: the model (4-60MB) and the clip (~600KB) are parsed on a
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

    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var loadedCharacter = ""
    private var loadedDance = ""

    /// The model parsed ahead of time, keyed by the character it belongs to.
    private var prewarmKey = ""
    private var prewarmTask: Task<SCNScene?, Never>?

    var isAnimating: Bool { player != nil }

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
        guard let clip = await clip(for: dance) else { return false }
        player = MocapPlayer(clip: clip, retargeter: rt)
        player?.start()
        loadedDance = dance
        NSLog("[Performer] %@: %@ performing %@ (%d frames)", owner, character, dance, clip.frames.count)
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

    private func clip(for dance: String) async -> MocapClip? {
        guard let path = RemoteAssets.shared.dance(dance)?.clip else {
            NSLog("[Performer] %@ is not in the catalog", dance)
            return nil
        }
        guard let url = try? await RemoteAssets.shared.resolve(path) else {
            NSLog("[Performer] failed to download/locate clip %@", path)
            return nil
        }
        guard let clip = await Task.detached(priority: .userInitiated, operation: { MocapClip.load(url) }).value else {
            // Whatever is cached under that name does not parse. Drop it so the next attempt
            // re-downloads instead of failing identically on every launch.
            RemoteAssets.shared.evict(path)
            return nil
        }
        return clip
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
    }

    /// Drive the skeleton from live pose landmarks (camera or video source).
    func drive(_ world: [simd_float3]) { retargeter?.apply(world: world) }

    /// Always call this when the view goes away: `CADisplayLink(target:)` retains its target, so a
    /// player left running keeps burning CPU after the page is dismissed.
    func stop() {
        player?.stop()
        player = nil
        loadedDance = ""
    }
}
