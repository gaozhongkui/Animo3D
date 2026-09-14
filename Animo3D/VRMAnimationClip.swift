//
//  VRMAnimationClip.swift
//  Animo3D
//
//  Reads a `.vrma` take (the `VRMC_vrm_animation` glTF extension) and retargets it onto the
//  humanoid bones of a VRM model loaded through VRMSceneKit.
//
//  Why this file parses glTF itself instead of asking VRMKit: VRMKit does model the extension
//  (`VRMKit.VRMAnimation`), but it keeps the glTF animation channels, samplers and buffer
//  accessors at `package` visibility, and the only runtime that applies a take lives in
//  VRMRealityKit - RealityKit, iOS 18, neither of which this app is on. A `.vrma` is a plain GLB
//  whose animation data is float accessors, so reading the four arrays this needs is shorter than
//  working around either limit.
//
//  The retarget is the one the spec prescribes: both skeletons rest in (near) T-pose, so a source
//  bone's local rotation carries over once it is re-expressed between the two rest orientations,
//  and the hips translation scales by the ratio of the two rest hip heights. A VRM 0.x model faces
//  the other way than a `.vrma` is authored in, so its whole animation turns 180 degrees about Y.
//

import Foundation
import SceneKit
import simd

// MARK: - Clip

/// One `.vrma` take: the rest pose of the skeleton it was authored on, which of those bones the
/// VRM humanoid names, and the sampled channels.
struct VRMAnimationClip {

    /// A rest-pose node of the animation's own skeleton. Scale is not read: the spec forbids
    /// scaling humanoid bones and no exporter writes it.
    struct Node {
        var parent: Int?
        var localPosition: simd_float3
        var localRotation: simd_quatf
        /// Rest transform relative to the skeleton root, resolved once at parse time.
        var worldMatrix: simd_float4x4 = matrix_identity_float4x4
        var worldRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    struct RotationTrack {
        let times: [Float]
        let values: [simd_quatf]
        let stepped: Bool

        func value(at time: Float) -> simd_quatf {
            let (i, j, f) = sampleIndices(times, time)
            if stepped || i == j { return values[i] }
            return simd_slerp(values[i], values[j], f)
        }
    }

    struct VectorTrack {
        let times: [Float]
        let values: [simd_float3]
        let stepped: Bool

        func value(at time: Float) -> simd_float3 {
            let (i, j, f) = sampleIndices(times, time)
            if stepped || i == j { return values[i] }
            return mix(values[i], values[j], t: f)
        }
    }

    let nodes: [Node]
    /// VRM humanoid bone name (1.0 spelling, as the extension writes it) -> node index.
    let boneNode: [String: Int]
    let rotations: [Int: RotationTrack]
    /// Only the hips carry translation; the spec keeps every other humanoid bone's out.
    let hipsTranslation: VectorTrack?
    let duration: Float

    /// Parse a `.vrma`. Cheap enough to sit on a background task; a 23 second take is ~600KB.
    static func load(_ url: URL) -> VRMAnimationClip? {
        guard let data = try? Data(contentsOf: url) else {
            NSLog("[VRMA] cannot read %@", url.lastPathComponent)
            return nil
        }
        return load(data: data)
    }

    static func load(data: Data) -> VRMAnimationClip? {
        guard let (json, bin) = splitGLB(data) else {
            NSLog("[VRMA] not a GLB container")
            return nil
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: json) else {
            NSLog("[VRMA] glTF JSON did not decode")
            return nil
        }
        guard let rawNodes = raw.nodes, !rawNodes.isEmpty,
              let animation = raw.animations?.first,
              let accessors = raw.accessors, let views = raw.bufferViews else {
            NSLog("[VRMA] no animation in file")
            return nil
        }
        guard let humanBones = raw.extensions?.VRMC_vrm_animation?.humanoid?.humanBones,
              !humanBones.isEmpty else {
            NSLog("[VRMA] file carries no VRMC_vrm_animation humanoid table")
            return nil
        }

        // Rest pose. Parents come from the children lists, so the root is whatever nobody claims.
        var nodes = rawNodes.map { node in
            Node(parent: nil,
                 localPosition: vector3(node.translation),
                 localRotation: quaternion(node.rotation))
        }
        for (index, node) in rawNodes.enumerated() {
            for child in node.children ?? [] where child >= 0 && child < nodes.count {
                nodes[child].parent = index
            }
        }
        // Resolved root-first: a parent's world transform is always in place before its children's.
        for index in resolveOrder(nodes) {
            let local = simd_float4x4(translation: nodes[index].localPosition,
                                      rotation: nodes[index].localRotation)
            if let parent = nodes[index].parent {
                nodes[index].worldMatrix = nodes[parent].worldMatrix * local
                nodes[index].worldRotation = nodes[parent].worldRotation * nodes[index].localRotation
            } else {
                nodes[index].worldMatrix = local
                nodes[index].worldRotation = nodes[index].localRotation
            }
        }

        var boneNode: [String: Int] = [:]
        for (name, bone) in humanBones where bone.node >= 0 && bone.node < nodes.count {
            boneNode[name] = bone.node
        }
        let hipsNode = boneNode["hips"]

        var rotations: [Int: RotationTrack] = [:]
        var hipsTranslation: VectorTrack?
        var duration: Float = 0

        for channel in animation.channels {
            guard let target = channel.target.node,
                  channel.sampler >= 0, channel.sampler < animation.samplers.count else { continue }
            let sampler = animation.samplers[channel.sampler]
            let interpolation = sampler.interpolation ?? "LINEAR"
            guard let times = read(accessor: sampler.input, accessors: accessors, views: views,
                                   bin: bin, components: 1),
                  !times.isEmpty else { continue }
            duration = max(duration, times.last ?? 0)

            switch channel.target.path {
            case "rotation":
                guard let flat = read(accessor: sampler.output, accessors: accessors, views: views,
                                      bin: bin, components: 4, interpolation: interpolation),
                      flat.count >= times.count * 4 else { continue }
                var values: [simd_quatf] = []
                values.reserveCapacity(times.count)
                for i in 0..<times.count {
                    values.append(simd_quatf(ix: flat[i * 4], iy: flat[i * 4 + 1],
                                             iz: flat[i * 4 + 2], r: flat[i * 4 + 3]))
                }
                rotations[target] = RotationTrack(times: times, values: values,
                                                  stepped: interpolation == "STEP")
            case "translation":
                // Everything but the hips is dropped: a take that carries other translations is
                // outside the spec, and applying them would stretch the target's bones.
                guard target == hipsNode else { continue }
                guard let flat = read(accessor: sampler.output, accessors: accessors, views: views,
                                      bin: bin, components: 3, interpolation: interpolation),
                      flat.count >= times.count * 3 else { continue }
                var values: [simd_float3] = []
                values.reserveCapacity(times.count)
                for i in 0..<times.count {
                    values.append(simd_float3(flat[i * 3], flat[i * 3 + 1], flat[i * 3 + 2]))
                }
                hipsTranslation = VectorTrack(times: times, values: values,
                                              stepped: interpolation == "STEP")
            default:
                // Scale is forbidden on humanoid bones and morph weights belong to expressions,
                // which this take does not carry.
                continue
            }
        }

        guard !rotations.isEmpty, duration > 0 else {
            NSLog("[VRMA] no usable rotation channels")
            return nil
        }
        return VRMAnimationClip(nodes: nodes, boneNode: boneNode, rotations: rotations,
                                hipsTranslation: hipsTranslation, duration: duration)
    }
}

// MARK: - glTF reading

private extension VRMAnimationClip {

    struct Raw: Decodable {
        struct Node: Decodable {
            let children: [Int]?
            let translation: [Float]?
            let rotation: [Float]?
        }
        struct BufferView: Decodable {
            let buffer: Int
            let byteOffset: Int?
            let byteLength: Int
            let byteStride: Int?
        }
        struct Accessor: Decodable {
            let bufferView: Int?
            let byteOffset: Int?
            let componentType: Int
            let count: Int
            let type: String
        }
        struct Animation: Decodable {
            struct Channel: Decodable {
                struct Target: Decodable {
                    let node: Int?
                    let path: String
                }
                let sampler: Int
                let target: Target
            }
            struct Sampler: Decodable {
                let input: Int
                let output: Int
                let interpolation: String?
            }
            let channels: [Channel]
            let samplers: [Sampler]
        }
        struct Extensions: Decodable {
            struct Animation: Decodable {
                struct Humanoid: Decodable {
                    struct Bone: Decodable { let node: Int }
                    let humanBones: [String: Bone]
                }
                let humanoid: Humanoid?
            }
            let VRMC_vrm_animation: Animation?
        }
        let nodes: [Node]?
        let accessors: [Accessor]?
        let bufferViews: [BufferView]?
        let animations: [Animation]?
        let extensions: Extensions?
    }

    static let glbMagic: UInt32 = 0x46546C67   // "glTF"
    static let chunkJSON: UInt32 = 0x4E4F534A  // "JSON"
    static let chunkBIN: UInt32 = 0x004E4942   // "BIN\0"

    /// Split a GLB into its JSON and BIN chunks. Only the embedded buffer is supported: a `.vrma`
    /// with an external `.bin` beside it is not something any exporter writes.
    static func splitGLB(_ data: Data) -> (json: Data, bin: Data)? {
        guard data.count > 20, u32(data, 0) == glbMagic, u32(data, 4) == 2 else { return nil }
        var json: Data?
        var bin: Data?
        var offset = 12
        while offset + 8 <= data.count {
            let length = Int(u32(data, offset))
            let type = u32(data, offset + 4)
            let start = offset + 8
            guard length >= 0, start + length <= data.count else { break }
            let chunk = data.subdata(in: start..<(start + length))
            if type == chunkJSON { json = chunk } else if type == chunkBIN { bin = chunk }
            offset = start + length
        }
        guard let json else { return nil }
        return (json, bin ?? Data())
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8
            | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }

    /// Read one float accessor as a flat array, `components` floats per element.
    ///
    /// `CUBICSPLINE` output stores in-tangent, value and out-tangent per key; the value is the
    /// middle of each triple, which is what sampling it linearly needs.
    static func read(accessor index: Int, accessors: [Raw.Accessor], views: [Raw.BufferView],
                     bin: Data, components: Int, interpolation: String = "LINEAR") -> [Float]? {
        guard index >= 0, index < accessors.count else { return nil }
        let accessor = accessors[index]
        guard accessor.componentType == 5126 else {            // GL_FLOAT
            NSLog("[VRMA] accessor %d is not float (componentType %d)", index, accessor.componentType)
            return nil
        }
        guard let viewIndex = accessor.bufferView, viewIndex >= 0, viewIndex < views.count else {
            return nil
        }
        let view = views[viewIndex]
        guard view.buffer == 0 else { return nil }             // the GLB BIN chunk

        let perKey = interpolation == "CUBICSPLINE" ? 3 : 1
        let elements = accessor.count
        let byteStride = view.byteStride ?? (components * 4)
        let start = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0)
        let needed = byteStride * (elements - 1) + components * 4
        guard start >= 0, elements > 0, start + needed <= bin.count else {
            NSLog("[VRMA] accessor %d overruns its buffer", index)
            return nil
        }

        var out: [Float] = []
        out.reserveCapacity((elements / perKey) * components)
        bin.withUnsafeBytes { raw in
            for element in Swift.stride(from: 0, to: elements, by: perKey) {
                // The middle of a cubic triple is the key's own value; LINEAR/STEP step by one.
                let source = perKey == 3 ? element + 1 : element
                let offset = start + source * byteStride
                for c in 0..<components {
                    out.append(raw.loadUnaligned(fromByteOffset: offset + c * 4, as: Float.self))
                }
            }
        }
        return out
    }

    static func vector3(_ values: [Float]?) -> simd_float3 {
        guard let v = values, v.count == 3 else { return .zero }
        return simd_float3(v[0], v[1], v[2])
    }

    static func quaternion(_ values: [Float]?) -> simd_quatf {
        guard let v = values, v.count == 4 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3])
    }

    /// Node indices ordered so every parent precedes its children.
    static func resolveOrder(_ nodes: [Node]) -> [Int] {
        var depth = [Int](repeating: -1, count: nodes.count)
        func resolve(_ index: Int) -> Int {
            if depth[index] >= 0 { return depth[index] }
            depth[index] = 0                                   // guards a malformed cycle
            if let parent = nodes[index].parent { depth[index] = resolve(parent) + 1 }
            return depth[index]
        }
        for i in nodes.indices { _ = resolve(i) }
        return nodes.indices.sorted { depth[$0] < depth[$1] }
    }
}

// MARK: - Sampling helpers

/// The keys either side of `time` and how far between them it falls.
private func sampleIndices(_ times: [Float], _ time: Float) -> (Int, Int, Float) {
    guard let first = times.first, let last = times.last else { return (0, 0, 0) }
    if time <= first { return (0, 0, 0) }
    if time >= last { return (times.count - 1, times.count - 1, 0) }
    var low = 0
    var high = times.count - 1
    while high - low > 1 {
        let mid = (low + high) / 2
        if times[mid] <= time { low = mid } else { high = mid }
    }
    let span = times[high] - times[low]
    return (low, high, span > 0 ? (time - times[low]) / span : 0)
}

private func mix(_ a: simd_float3, _ b: simd_float3, t: Float) -> simd_float3 { a + (b - a) * t }

private extension simd_float4x4 {
    init(translation: simd_float3, rotation: simd_quatf) {
        self.init(rotation)
        columns.3 = simd_float4(translation, 1)
    }

    func transform(point: simd_float3) -> simd_float3 {
        let v = self * simd_float4(point, 1)
        return simd_float3(v.x, v.y, v.z)
    }
}
