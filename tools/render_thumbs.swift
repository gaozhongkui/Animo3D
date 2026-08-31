//
//  render_thumbs.swift
//  Animo3D / tools
//
//  Offline character thumbnail renderer (macOS command line).
//
//  Why: on device the card thumbnails were produced by loading the full 3D model and rendering it
//  offscreen. Once models moved to the CDN that meant downloading 191MB just to fill a grid of nine
//  small pictures - the home screen sat on a spinner for minutes. These PNGs are ~50KB each, so the
//  grid paints instantly and the model is only fetched when the character is actually used.
//
//  The framing here mirrors CharacterSceneController (normalizeOrientation + the thumbnail branch of
//  setupFrontCamera) so the offline images match what the app renders on device.
//
//  Build & run:
//      swiftc -O tools/render_thumbs.swift -o /tmp/render_thumbs
//      /tmp/render_thumbs <out-dir> <model.scn> [more models...]
//

import Foundation
import SceneKit
import AppKit

let thumbSize = CGSize(width: 360, height: 460)

// MARK: - Bone naming (mirrors BoneScheme in MixamoBoneMap.swift)

struct Scheme {
    let hips, head, leftShoulder, rightShoulder, leftFoot, spine, leftArm, rightArm: String

    static let mixamo = Scheme(hips: "mixamorig_Hips", head: "mixamorig_Head",
                               leftShoulder: "mixamorig_LeftShoulder", rightShoulder: "mixamorig_RightShoulder",
                               leftFoot: "mixamorig_LeftFoot", spine: "mixamorig_Spine",
                               leftArm: "mixamorig_LeftArm", rightArm: "mixamorig_RightArm")

    static let vrm = Scheme(hips: "J_Bip_C_Hips", head: "J_Bip_C_Head",
                            leftShoulder: "J_Bip_L_Shoulder", rightShoulder: "J_Bip_R_Shoulder",
                            leftFoot: "J_Bip_L_Foot", spine: "J_Bip_C_Spine",
                            leftArm: "J_Bip_L_UpperArm", rightArm: "J_Bip_R_UpperArm")
}

// Two-band cel shading, copied verbatim from CharacterSceneController.toonRampModifier.
let toonRamp = """
#pragma body
float ndl  = dot(normalize(_surface.normal), normalize(_light.direction));
float band = smoothstep(0.18, 0.32, ndl);
float ramp = mix(0.55, 1.0, band);
_lightingContribution.diffuse = _light.intensity.rgb * ramp;
"""

let rimLight = """
#pragma body
float3 n = normalize(_surface.normal);
float3 v = normalize(_surface.view);
float rim = 1.0 - saturate(dot(n, v));
rim = pow(rim, 3.0) * 0.42;
_output.color.rgb += rim * float3(0.62, 0.70, 1.0) * _output.color.a;
"""

// MARK: - Rendering

func collectBones(_ root: SCNNode) -> [String: SCNNode] {
    var out: [String: SCNNode] = [:]
    root.enumerateChildNodes { node, _ in
        if let n = node.name { out[n] = node }
    }
    return out
}

func applyToonShading(_ root: SCNNode) {
    root.enumerateHierarchy { node, _ in
        guard let g = node.geometry else { return }
        for m in g.materials {
            m.lightingModel = .lambert
            m.specular.contents = NSColor.black
            m.shaderModifiers = [.lightingModel: toonRamp, .fragment: rimLight]
        }
    }
}

/// VRM skeletons collapse in SceneKit's T bind pose; the app puts them in an A-pose for any static
/// shot, and the thumbnail has to match.
func applyPortraitPose(_ bones: [String: SCNNode], _ s: Scheme) {
    func rotate(_ name: String, _ angle: Float, _ axis: simd_float3) {
        guard let b = bones[name] else { return }
        b.simdOrientation = simd_mul(b.simdOrientation, simd_quatf(angle: angle, axis: axis))
    }
    rotate(s.leftArm,  1.0, simd_float3(0, 0, 1))
    rotate(s.rightArm, -1.0, simd_float3(0, 0, 1))
    rotate(s.spine,   0.03, simd_float3(1, 0, 0))
    rotate(s.head,    0.03, simd_float3(1, 0, 0))
}

/// Bind poses come in arbitrarily oriented (VRoid exports are commonly Z-up); rotate the model
/// upright from its own bone positions rather than trusting the file's axes.
func normalizeOrientation(_ root: SCNNode, _ bones: [String: SCNNode], _ s: Scheme) {
    guard let hips = bones[s.hips]?.simdWorldPosition,
          let head = bones[s.head]?.simdWorldPosition,
          let lsh = bones[s.leftShoulder]?.simdWorldPosition,
          let rsh = bones[s.rightShoulder]?.simdWorldPosition else { return }
    let up = simd_normalize(head - hips)
    let right0 = simd_normalize(lsh - rsh)
    let forward = simd_normalize(simd_cross(right0, up))
    let right = simd_normalize(simd_cross(up, forward))
    root.simdOrientation = simd_quatf(simd_float3x3(right, up, forward)).inverse
}

func addLights(_ scene: SCNScene) {
    let key = SCNNode()
    key.light = SCNLight(); key.light?.type = .omni; key.light?.intensity = 620
    key.position = SCNVector3(0, 100, 100)
    scene.rootNode.addChildNode(key)

    let ambient = SCNNode()
    ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 380
    scene.rootNode.addChildNode(ambient)

    let sun = SCNNode()
    let l = SCNLight(); l.type = .directional; l.intensity = 700
    l.castsShadow = false          // no floor in a thumbnail, so a shadow pass buys nothing
    sun.light = l
    sun.eulerAngles = SCNVector3(-Float.pi / 2.2, Float.pi / 12, 0)
    scene.rootNode.addChildNode(sun)
}

func render(model url: URL) -> NSImage? {
    guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
        FileHandle.standardError.write("  ! cannot open \(url.lastPathComponent)\n".data(using: .utf8)!)
        return nil
    }
    let scene = SCNScene()
    let root = loaded.rootNode
    root.removeAllAnimations()
    root.enumerateChildNodes { node, _ in node.removeAllAnimations() }
    scene.rootNode.addChildNode(root)

    let bones = collectBones(root)
    let isVRM = bones["J_Bip_C_Hips"] != nil
    let s: Scheme = isVRM ? .vrm : .mixamo
    if isVRM {
        applyToonShading(root)
        applyPortraitPose(bones, s)
    }
    normalizeOrientation(root, bones, s)

    guard let hips = bones[s.hips]?.simdWorldPosition,
          let head = bones[s.head]?.simdWorldPosition,
          let foot = bones[s.leftFoot]?.simdWorldPosition else {
        FileHandle.standardError.write("  ! no skeleton in \(url.lastPathComponent)\n".data(using: .utf8)!)
        return nil
    }
    let height = abs(head.y - foot.y)
    guard height > 0 else { return nil }
    let center = SCNVector3(CGFloat(hips.x), CGFloat((head.y + foot.y) / 2), CGFloat(hips.z))

    let cam = SCNNode()
    cam.camera = SCNCamera()
    cam.camera?.zNear = Double(height) * 0.01
    cam.camera?.zFar = Double(height) * 50
    cam.camera?.wantsHDR = true
    cam.camera?.wantsExposureAdaptation = false
    cam.camera?.exposureOffset = -0.1
    cam.camera?.fieldOfView = 62
    cam.position = SCNVector3(center.x, center.y, center.z + CGFloat(height * 1.9))
    cam.look(at: center)
    scene.rootNode.addChildNode(cam)

    addLights(scene)
    scene.background.contents = nil

    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let r = SCNRenderer(device: device, options: nil)
    r.autoenablesDefaultLighting = true      // matches ThumbRenderer.snapshot()
    r.scene = scene
    r.pointOfView = cam
    _ = r.prepare(scene.rootNode, shouldAbortBlock: nil)
    return r.snapshot(atTime: 0, with: thumbSize, antialiasingMode: .multisampling4X)
}

func writePNG(_ image: NSImage, to url: URL) -> Int {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return 0 }
    try? png.write(to: url)
    return png.count
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: render_thumbs <out-dir> <model> [model...]")
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var failures = 0
for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let key = url.deletingPathExtension().lastPathComponent
    guard let img = render(model: url) else { failures += 1; continue }
    let out = outDir.appendingPathComponent("thumb_\(key).png")
    let n = writePNG(img, to: out)
    print(String(format: "  %-34s %6.1f KB", (key as NSString).utf8String!, Double(n) / 1024))
}
exit(failures > 0 ? 1 : 0)
