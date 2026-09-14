//
//  VRMCharacter.swift
//  Animo3D
//
//  Mounting a `.vrm` the user brought in themselves.
//
//  Every character that ships with the app is a `.scn` built by tools/auto_rig.py off a Mixamo
//  skeleton, which is why the rest of the app can address bones through one fixed table of names.
//  A file the user picked out of Files has none of that: its nodes are named however its author
//  named them - `J_Bip_C_Hips`, `Bone_014`, a word in Japanese - and the only thing that can be
//  relied on is the humanoid table inside the file.
//
//  So this is the whole of what is special about an imported model: parse it, and read its
//  humanoid table into a `BoneScheme`. From there `CharacterSceneController` mounts it like any
//  other character, and the `.vrma` player, the retargeter, the camera and the thumbnail renderer
//  never learn that there are two kinds of character.
//
//  Everything VRM-shaped is confined to this file, which is also where the deprecation lives.
//  VRMSceneKit is deprecated upstream in favour of VRMRealityKit; that is no use here, because the
//  stage, the recorder, the AR view and every thumbnail are SceneKit, and a second renderer for one
//  feature is a worse trade than staying on the deprecated loader. Keeping the calls in one file
//  keeps the warnings in one file, and keeps VRM types out of the rest of the app.
//

import SceneKit
import VRMKit
import VRMSceneKit

enum VRMCharacter {
    /// Is this a file we would try to open as a character?
    ///
    /// `UTType(filenameExtension: "vrm")` answers nil - the system has no type registered for the
    /// extension - so the file importer has to accept a wider type than we want, and the real check
    /// lands here.
    static func isVRM(_ url: URL) -> Bool { url.pathExtension.lowercased() == "vrm" }

    /// Parse a `.vrm` into a scene this app can mount. Nil when the file is not a readable VRM.
    static func loadScene(at url: URL) -> SCNScene? {
        do {
            return try VRMSceneLoader(withURL: url).loadScene()
        } catch {
            NSLog("[VRM] %@ did not parse: %@", url.lastPathComponent, String(describing: error))
            return nil
        }
    }

    /// The VRM root inside a scene this loaded, or nil for anything else.
    static func node(in scene: SCNScene) -> SCNNode? { (scene as? VRMScene)?.vrmNode }

    /// The bone scheme for a mounted VRM, read from the humanoid table the file ships.
    ///
    /// Nil when the model is missing a bone the app cannot work without. That is worth failing on:
    /// a humanoid with no hips or no shoulders cannot be posed by a take, framed by the camera or
    /// planted on the floor, and mounting it anyway gives the user a character that is visibly
    /// broken rather than one that is honestly refused.
    static func scheme(for node: SCNNode) -> BoneScheme? {
        guard let vrm = node as? VRMNode else { return nil }
        return BoneScheme.vrm { vrm.humanoid.node(for: $0)?.name }
    }

    /// Every humanoid bone the file declares, keyed by the name a `.vrma` calls it.
    ///
    /// Serves both jobs an imported model needs: the take player looks a bone up by name here
    /// instead of through `MixamoBoneMap`, and the camera measures its framing against the whole
    /// set. A Mixamo rig is found by name prefix; a VRM has no prefix to look for, and its humanoid
    /// set spans the body anyway, which is what framing actually wants.
    static func humanoidNodes(of node: SCNNode) -> [String: SCNNode] {
        guard let vrm = node as? VRMNode else { return [:] }
        return HumanoidBone.allCases.reduce(into: [:]) { out, bone in
            out[bone.rawValue] = vrm.humanoid.node(for: bone)
        }
    }

    /// Step the model's own physics - the spring bones the file defines, plus look-at and
    /// constraints.
    ///
    /// A VRM states where its hair and skirt bones are and how stiff they should be. That is real
    /// data, and strictly better than the name-matching heuristic the bundled `.scn` characters
    /// have to be driven by, so an imported model is left to drive itself.
    static func step(_ node: SCNNode, at time: TimeInterval) {
        (node as? VRMNode)?.update(at: time)
    }
}
