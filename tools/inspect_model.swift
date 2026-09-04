//
//  inspect_model.swift
//  Animo3D / tools
//
//  Loads a character through SceneKit exactly the way the app does and reports whether it is
//  actually usable: does it have the skeleton the retargeter needs, is it upright, does it carry
//  its textures. A converted model that opens fine in Blender or Preview can still arrive in
//  SceneKit with no materials or a collapsed rig, and that is only visible from here.
//
//  Build & run:
//      swiftc -O tools/inspect_model.swift -o /tmp/inspect_model
//      /tmp/inspect_model <model.usdz|model.scn> [more...]
//

import Foundation
import SceneKit

struct Report {
    var ok = true
    var lines: [String] = []
    mutating func pass(_ s: String) { lines.append("  ok   \(s)") }
    mutating func fail(_ s: String) { lines.append("  FAIL \(s)"); ok = false }
    mutating func warn(_ s: String) { lines.append("  warn \(s)") }
}

let vrmKeyBones = ["J_Bip_C_Hips", "J_Bip_C_Head", "J_Bip_L_Shoulder", "J_Bip_R_Shoulder",
                   "J_Bip_L_UpperArm", "J_Bip_R_UpperArm", "J_Bip_L_Foot", "J_Bip_R_Foot"]
let mixamoKeyBones = ["mixamorig_Hips", "mixamorig_Head", "mixamorig_LeftShoulder",
                      "mixamorig_RightShoulder", "mixamorig_LeftFoot"]

func inspect(_ path: String) -> Report {
    var r = Report()
    let url = URL(fileURLWithPath: path)
    guard let scene = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
        r.fail("SceneKit cannot open this file")
        return r
    }
    let root = scene.rootNode

    var bones: [String: SCNNode] = [:]
    var geometries = 0, materials = 0, textured = 0, skinned = 0, animated = 0
    root.enumerateChildNodes { node, _ in
        if let n = node.name { bones[n] = node }
        animated += node.animationKeys.count
        guard let g = node.geometry else { return }
        geometries += 1
        if node.skinner != nil { skinned += 1 }
        for m in g.materials {
            materials += 1
            if m.diffuse.contents != nil { textured += 1 }
        }
    }

    let isVRM = bones["J_Bip_C_Hips"] != nil
    r.pass("rig: \(isVRM ? "vrm" : "mixamo")  nodes: \(bones.count)  meshes: \(geometries)  skinned: \(skinned)")

    let needed = isVRM ? vrmKeyBones : mixamoKeyBones
    let missing = needed.filter { bones[$0] == nil }
    if missing.isEmpty { r.pass("all \(needed.count) key bones present") }
    else { r.fail("missing bones: \(missing.joined(separator: ", "))") }

    if skinned == 0 { r.fail("no skinned mesh - the skeleton will move but the body will not") }

    if materials == 0 { r.fail("no materials") }
    else if textured == 0 { r.fail("\(materials) materials but not one has a diffuse texture (the classic all-white USD export)") }
    else if textured < materials { r.warn("\(textured)/\(materials) materials carry a texture") }
    else { r.pass("\(materials) materials, all textured") }

    // Orientation and scale, measured the way the app measures them. Bind poses arrive in whatever
    // axis convention the exporter felt like (Z-up is normal for a Mixamo .scn), so the file being
    // "wrong" here is not itself a problem - normalizeOrientation rotates it upright from the bone
    // positions. What matters is that the result stands up and comes out a plausible height, since
    // stage framing, ground placement and AR scale are all derived from it.
    let hipsName = isVRM ? "J_Bip_C_Hips" : "mixamorig_Hips"
    let headName = isVRM ? "J_Bip_C_Head" : "mixamorig_Head"
    let footName = isVRM ? "J_Bip_L_Foot" : "mixamorig_LeftFoot"
    if let hips = bones[hipsName]?.simdWorldPosition,
       let head = bones[headName]?.simdWorldPosition,
       let lsh = bones[isVRM ? "J_Bip_L_Shoulder" : "mixamorig_LeftShoulder"]?.simdWorldPosition,
       let rsh = bones[isVRM ? "J_Bip_R_Shoulder" : "mixamorig_RightShoulder"]?.simdWorldPosition {
        let upAxis = simd_normalize(head - hips)
        r.pass(String(format: "file axis: up = (%.2f, %.2f, %.2f)%@",
                      upAxis.x, upAxis.y, upAxis.z, upAxis.y > 0.85 ? " (already Y-up)" : " (will be rotated upright)"))

        // Same maths as CharacterSceneController.normalizeOrientation.
        let forward = simd_normalize(simd_cross(simd_normalize(lsh - rsh), upAxis))
        let right = simd_normalize(simd_cross(upAxis, forward))
        root.simdOrientation = simd_quatf(simd_float3x3(right, upAxis, forward)).inverse

        if let head2 = bones[headName]?.simdWorldPosition, let foot2 = bones[footName]?.simdWorldPosition {
            let height = abs(head2.y - foot2.y)
            if height >= 0.5 && height <= 3 { r.pass(String(format: "stands %.2f m tall once upright", height)) }
            else { r.warn(String(format: "stands %.2f m once upright - the app expects roughly 1-2 m; check the export scale", height)) }
        }
    }

    if animated > 0 {
        r.warn("\(animated) baked animation(s) still attached; install() strips them, but they bloat the file")
    }

    if let attrs = try? FileManager.default.attributesOfItem(atPath: path), let b = attrs[.size] as? Int {
        let mb = Double(b) / 1e6
        if mb > 40 { r.warn(String(format: "%.1f MB - large enough to stall the stage load; consider --downscale 1024", mb)) }
        else { r.pass(String(format: "%.1f MB", mb)) }
    }
    return r
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: inspect_model <model.usdz|model.scn> [more...]")
    exit(2)
}
var bad = 0
for path in args.dropFirst() {
    print((path as NSString).lastPathComponent)
    let r = inspect(path)
    r.lines.forEach { print($0) }
    if !r.ok { bad += 1 }
}
exit(bad == 0 ? 0 : 1)
