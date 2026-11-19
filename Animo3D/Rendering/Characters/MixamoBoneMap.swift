//
//  MixamoBoneMap.swift
//  Animo3D
//
//  Mapping from BlazePose's 33 points to the standard Mixamo skeleton.
//  After USDZ conversion, Mixamo bone names carry the "mixamorig_" prefix (colons become underscores); the naming is fixed and universal.
//
//  BlazePose index reference:
//  11 left shoulder 12 right shoulder 13 left elbow 14 right elbow 15 left wrist 16 right wrist
//  23 left hip 24 right hip 25 left knee 26 right knee 27 left ankle 28 right ankle
//

import Foundation
import SceneKit
import VRMKit

enum MixamoBoneMap {

    /// One bone: the bone node plus its child node (used to derive the rest direction),
    /// together with a pair of BlazePose indices (used to derive the target direction).
    struct BoneDef {
        let node: String        // Bone node name
        let childNode: String   // Child bone node name (rest direction = the direction toward the child node)
        let from: Int           // Target direction start landmark
        let to: Int             // Target direction end landmark
    }

    /// Drive the limbs first (most visible, clearest child nodes). Torso and fingers can come later.
    /// Ordered parent-first, so a parent's world orientation is already updated during retargeting.
    static let bones: [BoneDef] = [
        // Left arm
        BoneDef(node: "mixamorig_LeftArm",      childNode: "mixamorig_LeftForeArm", from: 11, to: 13),
        BoneDef(node: "mixamorig_LeftForeArm",  childNode: "mixamorig_LeftHand",    from: 13, to: 15),
        // Right arm
        BoneDef(node: "mixamorig_RightArm",     childNode: "mixamorig_RightForeArm", from: 12, to: 14),
        BoneDef(node: "mixamorig_RightForeArm", childNode: "mixamorig_RightHand",    from: 14, to: 16),
        // Left leg
        BoneDef(node: "mixamorig_LeftUpLeg",    childNode: "mixamorig_LeftLeg",     from: 23, to: 25),
        BoneDef(node: "mixamorig_LeftLeg",      childNode: "mixamorig_LeftFoot",    from: 25, to: 27),
        // Right leg
        BoneDef(node: "mixamorig_RightUpLeg",   childNode: "mixamorig_RightLeg",    from: 24, to: 26),
        BoneDef(node: "mixamorig_RightLeg",     childNode: "mixamorig_RightFoot",   from: 26, to: 28),
        // Note: driving the head/neck throws the head backwards (the nose direction relative to the shoulder center is unstable), so it stays undriven - a forward-facing head looks more natural.
    ]

    /// Virtual landmark indices: 100 = shoulder center, 101 = hip center
    static let shoulderCenter = 100
    static let hipCenter = 101

    /// VRM humanoid bone (1.0 spelling, as a `.vrma` names it) -> the node name on our characters.
    ///
    /// This is what lets a `.vrma` take drive a Mixamo character as well as a VRM one: the take is
    /// bone rotations keyed by humanoid name, and `VRMAnimationPlayer` only ever asks "which node
    /// is this bone" - a VRM answers from its own humanoid table, a Mixamo rig answers from here.
    /// The thumb is the one joint the two VRM versions name differently; 1.0's metacarpal /
    /// proximal / distal is what a `.vrma` uses, and it is Mixamo's Thumb1 / 2 / 3.
    static let humanoid: [String: String] = {
        var map: [String: String] = [
            "hips": "Hips", "spine": "Spine", "chest": "Spine1", "upperChest": "Spine2",
            "neck": "Neck", "head": "Head",
        ]
        for (side, vrm) in [("Left", "left"), ("Right", "right")] {
            map["\(vrm)Shoulder"] = "\(side)Shoulder"
            map["\(vrm)UpperArm"] = "\(side)Arm"
            map["\(vrm)LowerArm"] = "\(side)ForeArm"
            map["\(vrm)Hand"] = "\(side)Hand"
            map["\(vrm)UpperLeg"] = "\(side)UpLeg"
            map["\(vrm)LowerLeg"] = "\(side)Leg"
            map["\(vrm)Foot"] = "\(side)Foot"
            map["\(vrm)Toes"] = "\(side)ToeBase"
            for (finger, mixamo) in [("Thumb", "Thumb"), ("Index", "Index"), ("Middle", "Middle"),
                                     ("Ring", "Ring"), ("Little", "Pinky")] {
                let joints = finger == "Thumb"
                    ? ["Metacarpal", "Proximal", "Distal"]
                    : ["Proximal", "Intermediate", "Distal"]
                for (n, joint) in joints.enumerated() {
                    map["\(vrm)\(finger)\(joint)"] = "\(side)Hand\(mixamo)\(n + 1)"
                }
            }
        }
        return map.mapValues { "mixamorig_" + $0 }
    }()

    static let rootNode = "mixamorig_Hips"
}

/// What the retargeter needs from whatever holds the skeleton.
///
/// A protocol rather than the concrete controller so `tools/render_thumbs.swift` can compile
/// PoseRetargeter.swift as-is and produce the dance card art with the exact same pose maths the app
/// runs. The alternative was a second copy of that maths inside the tool, and a second copy is a
/// copy that drifts - the card art would slowly stop matching what the stage shows.
protocol BoneRig: AnyObject {
    var scheme: BoneScheme { get }
    var boneNodes: [String: SCNNode] { get }
    var isLoaded: Bool { get }
    /// World Y of the ground the character stands on, or nil when there is no ground to stand on
    /// (offscreen thumbnail renders). Foot planting needs the real plane, not a bone's rest height.
    var groundY: Float? { get }
}

/// The named bones the retargeter and the framing code need, in one place.
struct BoneScheme {
    let bones: [MixamoBoneMap.BoneDef]   // 8 limb bones (character drive)
    // Used for pose normalization and framing
    let hips: String
    let head: String
    let leftShoulder: String
    let rightShoulder: String
    let leftFoot: String
    let rightFoot: String
    let leftHand: String
    let rightHand: String
    /// Toe bones. A pointed toe drops the sole well below the ankle, so planting that watches only
    /// the foot bone reads level while the boot is already through the floor.
    let leftToe: String
    let rightToe: String
    let spine: String
    let chest: String?
    let upperChest: String?
    /// Spine bone that drives torso twist and lean (between hips and shoulders)
    // Used for the torso frame
    let leftArm: String
    let rightArm: String
    let leftUpLeg: String
    let rightUpLeg: String

    /// Mixamo (our bundled characters)
    static let mixamo = BoneScheme(
        bones: MixamoBoneMap.bones,
        hips: "mixamorig_Hips", head: "mixamorig_Head",
        leftShoulder: "mixamorig_LeftShoulder", rightShoulder: "mixamorig_RightShoulder",
        leftFoot: "mixamorig_LeftFoot", rightFoot: "mixamorig_RightFoot",
        leftHand: "mixamorig_LeftHand", rightHand: "mixamorig_RightHand",
        leftToe: "mixamorig_LeftToeBase", rightToe: "mixamorig_RightToeBase",
        spine: "mixamorig_Spine", chest: "mixamorig_Spine1", upperChest: "mixamorig_Spine2",
        leftArm: "mixamorig_LeftArm", rightArm: "mixamorig_RightArm",
        leftUpLeg: "mixamorig_LeftUpLeg", rightUpLeg: "mixamorig_RightUpLeg")

    /// The scheme for a model that ships its own VRM humanoid table.
    ///
    /// A `.vrm` names its nodes however its author felt like - `J_Bip_C_Hips`, `Bone_014`, a word
    /// in Japanese - so no fixed table of names can address one. The humanoid table in the file is
    /// the one reliable way in: resolve every landmark this app needs through it once, at install,
    /// and the rest of the app goes on addressing bones by node name exactly as it does a Mixamo
    /// rig, with nothing else needing to know which kind of model is mounted.
    ///
    /// Returns nil when the model is missing a bone the app cannot work without - an incomplete
    /// humanoid is better refused at import than mounted and broken.
    static func vrm(_ name: (HumanoidBone) -> String?) -> BoneScheme? {
        guard let hips = name(.hips), let head = name(.head),
              let leftShoulder = name(.leftShoulder), let rightShoulder = name(.rightShoulder),
              let leftFoot = name(.leftFoot), let rightFoot = name(.rightFoot),
              let leftHand = name(.leftHand), let rightHand = name(.rightHand),
              let spine = name(.spine),
              let leftArm = name(.leftUpperArm), let rightArm = name(.rightUpperArm),
              let leftForeArm = name(.leftLowerArm), let rightForeArm = name(.rightLowerArm),
              let leftUpLeg = name(.leftUpperLeg), let rightUpLeg = name(.rightUpperLeg),
              let leftLeg = name(.leftLowerLeg), let rightLeg = name(.rightLowerLeg)
        else { return nil }

        let chest = name(.chest)
        let upperChest = name(.upperChest)

        // Toes are optional in VRM 1.0. Foot planting reads the toe when there is one and the
        // ankle otherwise, so falling back to the foot degrades the plant rather than failing.
        let leftToe = name(.leftToes) ?? leftFoot
        let rightToe = name(.rightToes) ?? rightFoot

        // The same eight limb bones, against this model's own node names. The BlazePose indices are
        // properties of the human body, not of the rig, so they carry over unchanged.
        let bones: [MixamoBoneMap.BoneDef] = [
            MixamoBoneMap.BoneDef(node: leftArm,      childNode: leftForeArm,  from: 11, to: 13),
            MixamoBoneMap.BoneDef(node: leftForeArm,  childNode: leftHand,     from: 13, to: 15),
            MixamoBoneMap.BoneDef(node: rightArm,     childNode: rightForeArm, from: 12, to: 14),
            MixamoBoneMap.BoneDef(node: rightForeArm, childNode: rightHand,    from: 14, to: 16),
            MixamoBoneMap.BoneDef(node: leftUpLeg,    childNode: leftLeg,      from: 23, to: 25),
            MixamoBoneMap.BoneDef(node: leftLeg,      childNode: leftFoot,     from: 25, to: 27),
            MixamoBoneMap.BoneDef(node: rightUpLeg,   childNode: rightLeg,     from: 24, to: 26),
            MixamoBoneMap.BoneDef(node: rightLeg,     childNode: rightFoot,    from: 26, to: 28),
        ]

        return BoneScheme(bones: bones,
                          hips: hips, head: head,
                          leftShoulder: leftShoulder, rightShoulder: rightShoulder,
                          leftFoot: leftFoot, rightFoot: rightFoot,
                          leftHand: leftHand, rightHand: rightHand,
                          leftToe: leftToe, rightToe: rightToe,
                          spine: spine, chest: chest, upperChest: upperChest,
                          leftArm: leftArm, rightArm: rightArm,
                          leftUpLeg: leftUpLeg, rightUpLeg: rightUpLeg)
    }

}
