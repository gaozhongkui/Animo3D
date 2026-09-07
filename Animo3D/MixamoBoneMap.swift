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
    let spine: String   // Spine bone that drives torso twist and lean (between hips and shoulders)
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
        leftFoot: "mixamorig_LeftFoot", spine: "mixamorig_Spine",
        leftArm: "mixamorig_LeftArm", rightArm: "mixamorig_RightArm",
        leftUpLeg: "mixamorig_LeftUpLeg", rightUpLeg: "mixamorig_RightUpLeg")

}
