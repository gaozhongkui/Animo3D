//
//  render_thumbs.swift
//  Animo3D / tools
//
//  Offline card art renderer (macOS command line): one PNG per character, one per dance.
//
//  Why: both grids used to be rendered on device from the full 3D model. Once models moved to the
//  CDN that meant downloading 191MB to fill nine small pictures, and 26MB of dance clips to fill
//  forty-four. These PNGs are ~50KB each, so a grid paints instantly and a model is fetched only
//  when the character is actually performed.
//
//  Character cards ship in the index and are the reason that grid paints instantly.
//
//  The `dances` mode is not part of the asset pipeline - the app renders dance cards itself, from
//  the built-in character plus the clip. It is here to check offline what a card will look like
//  (and that a newly sampled take poses correctly) without building and installing the app. Pose
//  maths is not reimplemented for it: this compiles the app's own PoseRetargeter, so what it shows
//  is exactly what the device will draw.
//
//  Build & run:
//      swiftc -O tools/render_thumbs.swift Animo3D/PoseRetargeter.swift Animo3D/MixamoBoneMap.swift \
//          -o /tmp/render_thumbs
//      /tmp/render_thumbs characters <out-dir> <model.scn> [more models...]
//      /tmp/render_thumbs dances <out-dir> <showcase.scn> <clip.json> [more clips...]
//

import Foundation
import SceneKit
import AppKit

let thumbSize = CGSize(width: 360, height: 460)

// MARK: - Bone rig shim
//
// PoseRetargeter only needs these three members; the protocol exists so this file can hand it a
// plain skeleton holder instead of the app's SwiftUI controller.

final class Rig: BoneRig {
    let scheme = BoneScheme.mixamo
    var boneNodes: [String: SCNNode] = [:]
    var isLoaded = false
}

/// The frame a dance card poses on, matching ThumbRenderer.signatureFrame.
let signatureFrame = 0.45

/// One mocap take. The format is `{fps, frames: [[[x,y,z], ...33]]}`.
func loadFrames(_ url: URL) -> [[simd_float3]] {
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = obj["frames"] as? [[[Double]]] else { return [] }
    return raw.map { $0.map { simd_float3(Float($0[0]), Float($0[1]), Float($0[2])) } }
}

// MARK: - Rendering

func collectBones(_ root: SCNNode) -> [String: SCNNode] {
    var out: [String: SCNNode] = [:]
    root.enumerateChildNodes { node, _ in
        if let n = node.name { out[n] = node }
    }
    return out
}

/// Bind poses come in arbitrarily oriented (VRoid exports are commonly Z-up); rotate the model
/// upright from its own bone positions rather than trusting the file's axes.
func normalizeOrientation(_ root: SCNNode, _ bones: [String: SCNNode], _ s: BoneScheme) {
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

func render(model url: URL, pose: [simd_float3]? = nil) -> NSImage? {
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
    let s = BoneScheme.mixamo
    normalizeOrientation(root, bones, s)

    if let pose {
        // The retargeter smooths over time, so the same frame is applied until it converges - the
        // app's ThumbRenderer does exactly this.
        let rig = Rig()
        rig.boneNodes = bones
        rig.isLoaded = true
        let rt = PoseRetargeter(controller: rig)
        rt.resetCapture()
        for _ in 0..<12 { rt.apply(world: pose) }
    }

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
//
// Wrapped in a @main type rather than written at the top level: this file is compiled together with
// the app's PoseRetargeter.swift, and Swift only allows top-level statements in main.swift.

@main
struct Tool {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4, args[1] == "characters" || args[1] == "dances" else {
            print("""
            usage: render_thumbs characters <out-dir> <model.scn> [model...]
                   render_thumbs dances     <out-dir> <showcase.scn> <clip.json> [clip...]
            """)
            exit(2)
        }
        let outDir = URL(fileURLWithPath: args[2])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var failures = 0

        func emit(_ img: NSImage, prefix: String, key: String) {
            let n = writePNG(img, to: outDir.appendingPathComponent("\(prefix)_\(key).png"))
            print(String(format: "  %-36s %6.1f KB", (key as NSString).utf8String!, Double(n) / 1024))
        }

        if args[1] == "characters" {
            for path in args.dropFirst(3) {
                let url = URL(fileURLWithPath: path)
                guard let img = render(model: url) else { failures += 1; continue }
                emit(img, prefix: "thumb", key: url.deletingPathExtension().lastPathComponent)
            }
        } else {
            let showcase = URL(fileURLWithPath: args[3])
            print("showcase: \(showcase.lastPathComponent)")
            for path in args.dropFirst(4) {
                let url = URL(fileURLWithPath: path)
                let key = url.deletingPathExtension().lastPathComponent
                let frames = loadFrames(url)
                guard !frames.isEmpty else {
                    FileHandle.standardError.write("  ! no frames in \(url.lastPathComponent)\n".data(using: .utf8)!)
                    failures += 1; continue
                }
                let idx = min(Int(Double(frames.count) * signatureFrame), frames.count - 1)
                guard let img = render(model: showcase, pose: frames[idx]) else { failures += 1; continue }
                emit(img, prefix: "card", key: key)
            }
        }
        exit(failures > 0 ? 1 : 0)
    }
}
