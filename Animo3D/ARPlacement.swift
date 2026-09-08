//
//  ARPlacement.swift
//  Animo3D
//
//  The parts of "put this thing on the real floor" that are identical whether the thing is a
//  dancing character or a static model from the community feed.
//
//  Extracted rather than copied. The placement logic had already gone wrong twice in one file, in
//  ways a second copy would have inherited: the reticle asked for an estimated plane while the tap
//  preferred real plane geometry, so the two resolved to different surfaces and the character
//  landed somewhere the reticle had never pointed; and an unbounded raycast happily returned a hit
//  tens of metres away, which put the model somewhere nobody aimed.
//

import ARKit
import SceneKit

enum ARPlacement {
    /// How far a hit on a surface ARKit has actually measured may be. A real detected plane 10 m
    /// away is just a large room, so this is generous.
    static let measuredRange: ClosedRange<Float> = 0.3...12.0

    /// How far a hit on a *guessed* surface may be. An `.estimatedPlane` raycast with few feature
    /// points will happily return something tens of metres out, and placing there reads as "I
    /// tapped near me and it appeared on the horizon" - so guesses are kept close.
    static let estimatedRange: ClosedRange<Float> = 0.35...6.0

    /// One raycast, used by both the reticle and the tap, so what the reticle shows is exactly where
    /// a tap lands.
    ///
    /// Three targets, in descending order of how much ARKit actually knows:
    ///
    /// 1. `.existingPlaneGeometry` - inside the measured outline of a detected plane. Best answer.
    /// 2. `.existingPlaneInfinite` - the same plane, treated as the unbounded surface it physically
    ///    is. This is the one that was missing, and it is most of why finding the floor felt bad:
    ///    a plane's measured extent starts as a small patch under wherever the camera happened to
    ///    look and grows slowly, so aiming a metre to the left of it fell straight through to a
    ///    guess even though ARKit already knew perfectly well where the floor was.
    /// 3. `.estimatedPlane` - a plane inferred from raw feature points, used while nothing is
    ///    detected yet. Kept last, and kept near.
    static func floorHit(at point: CGPoint, in arView: ARSCNView) -> ARRaycastResult? {
        guard let camera = arView.session.currentFrame?.camera.transform else { return nil }
        let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)

        let targets: [(ARRaycastQuery.Target, ClosedRange<Float>)] = [
            (.existingPlaneGeometry, measuredRange),
            (.existingPlaneInfinite, measuredRange),
            (.estimatedPlane, estimatedRange),
        ]
        for (target, range) in targets {
            guard let q = arView.raycastQuery(from: point, allowing: target, alignment: .horizontal),
                  let hit = arView.session.raycast(q).first else { continue }
            let p = simd_float3(hit.worldTransform.columns.3.x,
                                hit.worldTransform.columns.3.y,
                                hit.worldTransform.columns.3.z)
            if range.contains(simd_distance(p, eye)) { return hit }
        }
        return nil
    }

    /// Loads a community model and gets it ready to show, wherever it is going to be shown.
    ///
    /// Both the AR screen and the turntable need exactly this sequence, and it is a sequence where
    /// order matters - textures capped before anything touches the GPU, the backdrop dropped before
    /// the scale is measured from what is left. Having it in one place is what stops the two paths
    /// from disagreeing about what the model is, which is the whole point of being able to compare
    /// them when something looks wrong.
    ///
    /// Returns a container node whose origin is the model's footprint centre at floor level, so the
    /// caller can drop it straight onto a plane or onto the turntable's origin.
    static func loadCommunityModel(url: URL, fitting targetSize: Float) -> SCNNode? {
        guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: true]) else {
            print("[CommunityModel] cannot open \(url.lastPathComponent)")
            return nil
        }
        let model = SCNNode()
        for child in loaded.rootNode.childNodes { model.addChildNode(child) }

        // Whatever the author baked in, on a loop. An imported clip plays once and stops, which for
        // an idle reads as the model freezing a few seconds after it appears.
        var clips = 0
        model.enumerateHierarchy { node, _ in
            for key in node.animationKeys {
                guard let player = node.animationPlayer(forKey: key) else { continue }
                player.animation.repeatCount = .greatestFiniteMagnitude
                player.animation.autoreverses = false
                player.play()
                clips += 1
            }
        }

        let cap = DeviceTier.isLowEnd ? 512 : 1024
        let shrunk = shrinkTextures(in: model, maxPixel: cap)
        let dropped = stripBackdrops(from: model)

        let container = SCNNode()
        container.addChildNode(model)

        let (lo, hi) = visibleBounds(of: model, in: container)
        let extent = hi - lo
        let longest = max(extent.x, max(extent.y, extent.z))
        if longest > 0.0001 {
            let scale = targetSize / longest
            model.simdScale = simd_float3(repeating: scale)
            model.simdPosition.y -= lo.y * scale
            // Centre the footprint on the origin too, so it does not stand off to one side of
            // wherever it was placed.
            model.simdPosition.x -= (lo.x + hi.x) / 2 * scale
            model.simdPosition.z -= (lo.z + hi.z) / 2 * scale
        }

        print("[CommunityModel] \(url.lastPathComponent): \(clips) clip(s), "
              + "\(shrunk) texture(s) capped at \(cap)px, \(dropped) backdrop(s) dropped, "
              + "fitted to \(targetSize)m")
        return container
    }

    /// Caps the texture resolution of a community model, in place.
    ///
    /// This is the other half of "animated community models come up blank", and the half that only
    /// shows on a real device. "Black Dragon with Idle Animation" ships fifteen distinct maps, most
    /// of them 2048x2048: **155 MB** of decompressed RGBA, nearer 205 MB once SceneKit builds
    /// mipmaps - for one model, on top of the app, ARKit's camera pipeline and the recorder. On a
    /// 2-3 GB device that is either a jetsam kill (the app vanishes to the home screen) or a failed
    /// texture upload (geometry draws untextured, or not at all). Both look like "blank" to the
    /// person holding the phone. Capped at 1024 the same model needs 55 MB; at 512, 14 MB.
    ///
    /// Nothing in the app limited this before. A community model is whatever a stranger uploaded,
    /// so the ceiling has to be imposed here rather than hoped for.
    ///
    /// **The textures are inside the archive.** SceneKit does not extract them - it points each
    /// material property at the `.usdz` itself with the byte range in the query string,
    /// `file:///…/model.usdz?offset=5433280&size=137471`. Handing that URL to ImageIO does not
    /// work: it ignores the query and sees a zip. So the range is read directly and decoded from
    /// memory, and decoded *at* the reduced size - the obvious load-then-redraw would allocate the
    /// full 16 MB bitmap first, which is the spike being avoided.
    @discardableResult
    static func shrinkTextures(in root: SCNNode, maxPixel: Int) -> Int {
        var cache: [String: UIImage] = [:]      // one map is used by several materials
        var shrunk = 0

        /// The bytes a `…usdz?offset=N&size=M` URL refers to.
        func embeddedData(_ url: URL) -> Data? {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let items = comps.queryItems,
                  let offset = items.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
                  let size = items.first(where: { $0.name == "size" })?.value.flatMap(Int.init),
                  let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: url.path))
            else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            return try? handle.read(upToCount: size)
        }

        func downsample(_ url: URL) -> UIImage? {
            if let hit = cache[url.absoluteString] { return hit }
            // A plain file URL (a model stored unarchived) still works: fall back to the whole file.
            let data = embeddedData(url) ?? (try? Data(contentsOf: URL(fileURLWithPath: url.path)))
            guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            cache[url.absoluteString] = image
            return image
        }

        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                let properties = [material.diffuse, material.metalness, material.roughness,
                                  material.normal, material.ambientOcclusion, material.emission,
                                  material.specular, material.selfIllumination,
                                  material.transparent, material.multiply, material.reflective,
                                  material.displacement]
                for property in properties {
                    guard let url = property.contents as? URL else { continue }
                    guard let small = downsample(url) else { continue }
                    property.contents = small
                    shrunk += 1
                }
            }
        }
        return shrunk
    }

    /// Removes the backdrop slabs authors bundle with their models.
    ///
    /// This is the rest of "the animated model shows up blank". Scaling was only half of it: with
    /// the scale taken from the dragon's own skeleton, the *plane* the author parked it on - 3537
    /// units across and 6 units thick, twelve triangles - came out as a 1.29 m dark plate with a
    /// 28 cm dragon standing in the middle of it. Rendered offscreen it covers 8% of the frame and
    /// almost all of that is plate; held up in a room at arm's length it is a dark slab lying on
    /// the floor, and the thing the user came to see is a few centimetres tall on top of it.
    ///
    /// The test is deliberately narrow, because deleting geometry from someone's model is not
    /// something to do on a hunch. A node has to be all four of:
    ///
    /// - part of a model that **has a skeleton** - the creature is the rigged part, so anything
    ///   unrigged is scenery or a prop;
    /// - **not skinned** itself;
    /// - **flat** - its thinnest axis under 3% of its longest. The dragon's plane is 0.18%. A sword
    ///   or a hat is nowhere near this;
    /// - **as big as the creature** - at least 60% of the skeleton's own footprint. A prop held in
    ///   a hand is a fraction of it.
    ///
    /// Nothing that describes a real part of a character passes all four.
    @discardableResult
    static func stripBackdrops(from root: SCNNode) -> Int {
        var slo = simd_float3(repeating: .greatestFiniteMagnitude); var shi = -slo
        var hasSkeleton = false
        root.enumerateHierarchy { node, _ in
            guard let skinner = node.skinner else { return }
            for bone in skinner.bones {
                let p = bone.simdConvertPosition(.zero, to: root)
                slo = min(slo, p); shi = max(shi, p); hasSkeleton = true
            }
        }
        guard hasSkeleton else { return 0 }
        let rigFootprint = max(shi.x - slo.x, shi.z - slo.z)
        guard rigFootprint > 0 else { return 0 }

        // Collected first: removing nodes while enumerating the hierarchy mutates what is being
        // walked.
        var doomed: [SCNNode] = []
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil, node.skinner == nil else { return }
            let (a, b) = node.boundingBox
            var lo = simd_float3(repeating: .greatestFiniteMagnitude); var hi = -lo
            for x in [Float(a.x), Float(b.x)] {
                for y in [Float(a.y), Float(b.y)] {
                    for z in [Float(a.z), Float(b.z)] {
                        let p = node.simdConvertPosition(simd_float3(x, y, z), to: root)
                        lo = min(lo, p); hi = max(hi, p)
                    }
                }
            }
            let e = hi - lo
            let longest = max(e.x, max(e.y, e.z))
            let thinnest = min(e.x, min(e.y, e.z))
            guard longest > 0 else { return }
            let isFlat = thinnest < longest * 0.03
            let isAsBigAsTheCreature = max(e.x, e.z) >= rigFootprint * 0.6
            if isFlat && isAsBigAsTheCreature { doomed.append(node) }
        }
        for node in doomed { node.removeFromParentNode() }
        return doomed.count
    }

    /// The session configuration both AR screens run.
    ///
    /// It was duplicated in each of them, which is how they drifted: neither ever asked for LiDAR
    /// scene reconstruction, so on a device that has it ARKit was being made to find the floor from
    /// camera feature points alone - the same way a six-year-old phone has to.
    ///
    /// Everything here is behind a capability check rather than a device-tier guess. A phone that
    /// cannot do these does not advertise them, and a phone that can is by definition new enough to
    /// afford them.
    static func makeConfiguration(detectGround: Bool = true) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = detectGround ? [.horizontal] : []
        config.environmentTexturing = .automatic

        // LiDAR. The mesh gives plane detection real geometry to agree with instead of a cloud of
        // feature points, which is the difference between finding the floor immediately and
        // sweeping the phone around waiting.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        // Depth, which the raycaster and the plane fitter both benefit from. Smoothed rather than
        // raw: this is used for placement, where stability matters more than latency.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        return config
    }

    /// Apple's own scanning guidance, switched back on - but driven by hand, not left to itself.
    ///
    /// It is worth having: it does the genuinely hard part, an animated phone-and-plane figure with
    /// per-reason instructions ("move slowly", "not enough light") in every language Apple ships,
    /// updated live from the session. Reimplementing that badly is worse than using it.
    ///
    /// `activatesAutomatically` is deliberately **off**. That is what made this a problem the first
    /// time: with it on, the overlay is up for as long as the goal is unmet, and it is a full-screen
    /// subview that swallows every touch while up. In a room ARKit cannot read - dark, or a plain
    /// floor - the goal is *never* met, so the overlay never leaves and the user can never tap. That
    /// is the "no plane found, and tapping does nothing" report, and removing the overlay entirely
    /// was an overcorrection.
    ///
    /// So the caller shows it on entry and takes it away on the first detected plane **or** after a
    /// timeout, whichever comes first. Guidance while it is useful, and control back regardless.
    @discardableResult
    static func installCoaching(on arView: ARSCNView,
                                delegate: ARCoachingOverlayViewDelegate) -> ARCoachingOverlayView {
        let coaching = ARCoachingOverlayView()
        coaching.session = arView.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = false
        coaching.delegate = delegate
        coaching.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.topAnchor.constraint(equalTo: arView.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
            coaching.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
        ])
        return coaching
    }

    /// How long the scanning overlay may hold the screen before the user gets control back even
    /// though no plane has been found. Long enough for a normal room to resolve, short enough that
    /// a room which never will does not become a dead end.
    static let coachingTimeout: TimeInterval = 15

    /// What to tell the user when tracking is not healthy, or nil when it is.
    ///
    /// Nothing was reported before: when ARKit could not find a surface the app said the same
    /// "slowly move your phone" as always, whatever the actual reason. Most of the time the reason
    /// is knowable and specific - the room is too dark or too plain, or the phone is being swung
    /// around too fast - and saying which is the difference between a user fixing it and a user
    /// concluding the feature is broken.
    static func trackingHint(for state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal:
            return nil
        case .notAvailable:
            return nil                      // starting up; the coach panel already covers this
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:   return L("Move your phone more slowly")
            case .insufficientFeatures: return L("Too dark or too plain here - try a floor with more texture")
            case .relocalizing:      return L("Finding your space again")
            case .initializing:      return nil
            @unknown default:        return nil
            }
        }
    }

    /// Yaw a placement so the model looks at the viewer.
    ///
    /// A horizontal raycast returns a transform aligned to the world axes, not to wherever the user
    /// happens to be standing, so without this a model is just as likely to be placed with its back
    /// turned. Only the Y rotation is taken - tilting it would look wrong.
    static func facingCamera(_ hit: simd_float4x4, from camera: simd_float4x4) -> simd_float4x4 {
        let target = simd_float3(hit.columns.3.x, hit.columns.3.y, hit.columns.3.z)
        let eye = simd_float3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        var d = eye - target
        d.y = 0
        guard simd_length(d) > 1e-4 else { return hit }
        let yaw = atan2(d.x, d.z)
        var t = matrix_identity_float4x4
        t.columns.3 = hit.columns.3
        return t * simd_float4x4(simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0)))
    }

    /// How far a placed model may be scaled, as a multiple of the size it was placed at. Unbounded
    /// before, so a pinch could shrink it to nothing or blow it past the far plane with no way back.
    static let scaleRange: ClosedRange<Float> = 0.35...3.0

    /// A modest, predictable rig for an AR scene.
    ///
    /// Environment texturing needs an A12 and a settled probe, so without these a model can come
    /// out black on older devices or right after launch. The directional light always casts: without
    /// a contact shadow the model does not read as standing on the real floor at all.
    static func addLights(to arView: ARSCNView) {
        guard arView.scene.rootNode.childNode(withName: "ar_lights", recursively: false) == nil else { return }
        let holder = SCNNode()
        holder.name = "ar_lights"

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 260
        holder.addChildNode(ambient)

        let sun = SCNNode()
        let l = SCNLight()
        l.type = .directional
        l.intensity = 420
        l.castsShadow = true
        l.shadowMode = .deferred
        l.shadowColor = UIColor(white: 0, alpha: 0.4)
        l.shadowRadius = 6
        l.shadowSampleCount = DeviceTier.shadowSampleCount
        sun.light = l
        sun.eulerAngles = SCNVector3(-Float.pi / 2.4, Float.pi / 10, 0)
        holder.addChildNode(sun)

        arView.scene.rootNode.addChildNode(holder)
    }

    /// An invisible disc under the model that exists only to catch its shadow.
    ///
    /// The rig casts one, but after placement the only other geometry in the scene - the detected
    /// plane visualisations - is hidden, so the shadow would fall on nothing and the model would
    /// read as a sticker over the camera feed. Writing no colour keeps the real floor visible
    /// through it while still receiving the shadow.
    static func addShadowCatcher(to container: SCNNode, size s: Float) {
        let side = CGFloat(max(s, 0.8) * 1.8)
        let plane = SCNPlane(width: side, height: side)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.white
        m.writesToDepthBuffer = false
        m.colorBufferWriteMask = []
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -Float.pi / 2
        node.castsShadow = false
        node.renderingOrder = -10
        container.addChildNode(node)
    }

    /// A ring-and-dot reticle that marks where a tap will land.
    static func makeReticle() -> SCNNode {
        let ring = SCNTorus(ringRadius: 0.14, pipeRadius: 0.006)
        ring.firstMaterial?.diffuse.contents = UIColor.systemGreen
        ring.firstMaterial?.lightingModel = .constant
        let node = SCNNode(geometry: ring)
        let dot = SCNNode(geometry: SCNSphere(radius: 0.012))
        dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemGreen
        dot.geometry?.firstMaterial?.lightingModel = .constant
        node.addChildNode(dot)
        node.isHidden = true
        return node
    }

    /// The bounds of what a model actually looks like, expressed in `space`.
    ///
    /// **Skinned meshes are measured from their bones, not their geometry.** `SCNNode.boundingBox`
    /// on a skinned mesh describes the vertex data as authored, before the skeleton moves any of
    /// it - and for a rigged model exported through Sketchfab's USDZ converter that box bears no
    /// relation to where the creature is. Measured on "Black Dragon with Idle Animation", the
    /// geometry boxes claim 3537 x 544 x 3537 units with the lowest point 542 units *below* the
    /// author's ground plane; the bones say 2749 x 766 x 1924 sitting exactly on y = 0. Every way
    /// of reading the geometry boxes gives the same wrong answer, SceneKit's own hierarchy box
    /// included, because they are all reading the same authored data.
    ///
    /// That wrong answer is what made animated community models invisible in AR: normalising a
    /// 544-unit "height" to one metre scaled the model by 0.0018, which turned the author's
    /// backdrop plane into a 6.5 m slab a metre in front of the camera and left the creature
    /// somewhere inside it.
    ///
    /// Bones also sidestep props the author bundled in - a backdrop plane is not part of the
    /// creature and should not set its scale.
    static func visibleBounds(of root: SCNNode, in space: SCNNode) -> (lo: simd_float3, hi: simd_float3) {
        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = -lo

        var sawBones = false
        root.enumerateHierarchy { node, _ in
            guard let skinner = node.skinner else { return }
            for bone in skinner.bones {
                let p = bone.simdConvertPosition(.zero, to: space)
                lo = min(lo, p); hi = max(hi, p)
                sawBones = true
            }
        }
        // A skeleton whose bones are all coincident measures nothing, and the caller would then
        // skip normalisation entirely and place the model at whatever scale the file declared.
        if sawBones, simd_reduce_max(hi - lo) > 1e-4 { return (lo, hi) }
        lo = simd_float3(repeating: .greatestFiniteMagnitude); hi = -lo

        // No usable skeleton: the geometry boxes are the authored shape and the right thing to read.
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] {
                for y in [Float(a.y), Float(b.y)] {
                    for z in [Float(a.z), Float(b.z)] {
                        let p = node.simdConvertPosition(simd_float3(x, y, z), to: space)
                        lo = min(lo, p); hi = max(hi, p)
                    }
                }
            }
        }
        return (lo, hi)
    }

    /// The lowest point of a model, expressed in `space`. Used to sit it on the container's origin
    /// so its base lands on the floor rather than through it.
    static func lowestY(of root: SCNNode, in space: SCNNode) -> Float {
        visibleBounds(of: root, in: space).lo.y
    }
}
