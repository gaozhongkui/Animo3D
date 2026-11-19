import Combine
import SceneKit
import simd

// Only the network and scene engine are controlled. Loading state, retry, cache eviction decisions
// and cancellation are exercised through the production DancePerformer and AssetDownloadWaiter.
@MainActor
final class RemoteAssets {
    static let shared = RemoteAssets()
    struct Character { let model: String }
    struct Dance { let clip: String }
    var characters = ["character": Character(model: "model"), "other": Character(model: "other-model")]
    var dances = ["dance": Dance(clip: "clip")]
    var evicted: [String] = []
    var resolveFile: (String) async throws -> URL = { URL(fileURLWithPath: "/" + $0) }

    func character(_ id: String) -> Character? { characters[id] }
    func dance(_ id: String) -> Dance? { dances[id] }
    func resolve(_ path: String) async throws -> URL { try await resolveFile(path) }
    func resolveCharacterModel(_ id: String) async throws -> URL {
        try await resolveFile(characters[id]!.model)
    }
    func evict(_ path: String) { evicted.append(path) }

    func reset() {
        evicted = []
        resolveFile = { URL(fileURLWithPath: "/" + $0) }
    }
}

@MainActor
final class CharacterSceneController {
    var groundEnabled = false
    var contactShadowOnly = false
    var characterRoot: SCNNode?
    var isLoaded = false
    var groundY: Float? { 0 }

    nonisolated static func loadSceneFile(at url: URL, warmUp: Bool) -> SCNScene? {
        guard url.lastPathComponent != "invalid-model" else { return nil }
        let scene = SCNScene()
        scene.rootNode.name = url.lastPathComponent
        return scene
    }
    func install(_ scene: SCNScene) {
        characterRoot = scene.rootNode
        isLoaded = scene.rootNode.name != "invalid-skeleton"
    }
    func tearDown() {
        characterRoot = nil
        isLoaded = false
    }
    func resetToRestPose() {}
    func endCameraFollow() {}
    func beginCameraFollow(aspect: Float) {}
    func stepCameraFollow() {}
    func humanoidNode(_ name: String) -> SCNNode? { nil }
    func posedBounds() -> (min: simd_float3, max: simd_float3)? { nil }
    func frameCamera(on bounds: (simd_float3, simd_float3), aspect: Float) {}
    func pause() {}
    func resume() {}
}

@MainActor
final class PoseRetargeter {
    init(controller: CharacterSceneController) {}
    func resetCapture() {}
    func apply(world: [simd_float3]) {}
}

final class VRMAnimationClip: @unchecked Sendable {
    let duration: Float = 1
    static func load(_ url: URL) -> VRMAnimationClip? {
        url.lastPathComponent == "invalid-clip" ? nil : VRMAnimationClip()
    }
}

@MainActor
final class VRMAnimationPlayer {
    var onFrame: ((Float) -> Void)?
    init?(
        clip: VRMAnimationClip,
        root: SCNNode,
        groundY: (() -> Float?)? = nil,
        bone: (String) -> SCNNode?
    ) {}
    func start() {}
    func stop() {}
    func pause() {}
    func resume() {}
    func rebase() {}
    func apply(at time: Float) {}
}

func L(_ value: String) -> String { NSLocalizedString(value, comment: "") }
