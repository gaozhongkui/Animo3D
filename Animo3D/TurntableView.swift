//
//  TurntableView.swift
//  Animo3D
//
//  A community model on a slow turntable, with no AR involved.
//
//  A plain `SCNView`, deliberately - not the `ARSCNView` the AR path uses. That view is driven by
//  its session: with no session running it does not advance its render loop, its light estimate
//  never arrives, and it reinstates its own `pointOfView` over the one you set. Working around each
//  of those left a black screen anyway. An `SCNView` just renders.
//
//  It earns its place twice over: it is the only way to look at a community model on a device
//  without ARKit (the Simulator included), and it is the control case when something looks wrong in
//  AR - if the model is right here and wrong there, the file and the download are fine and the
//  problem is placement.
//

import SceneKit
import SwiftUI

struct TurntableView: UIViewRepresentable {
    let url: URL
    /// Metres along the longest axis, matching the AR path so the two show the same size.
    var targetSize: Float = 1.6
    var onLoaded: ((Bool) -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .black
        view.allowsCameraControl = true          // drag to orbit, pinch to zoom
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = DeviceTier.antialiasing
        view.rendersContinuously = true          // the clip has to keep advancing
        view.isPlaying = true

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 620
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 950
        key.eulerAngles = SCNVector3(-Float.pi / 3, 0.5, 0)
        scene.rootNode.addChildNode(key)

        guard let container = ARPlacement.loadCommunityModel(url: url, fitting: targetSize) else {
            onLoaded?(false)
            return view
        }
        scene.rootNode.addChildNode(container)

        // Framed from the model's real bounds, not from `targetSize`. The two are not the same
        // thing: `targetSize` caps the *longest* axis, so a wide creature is only a fraction of it
        // tall - aiming at a fixed fraction of targetSize pointed the camera over the dragon's head
        // and left it sitting in the bottom of the frame.
        let (lo, hi) = ARPlacement.visibleBounds(of: container, in: container)
        let mid = (lo + hi) / 2
        let reach = max(simd_reduce_max(hi - lo), 0.1)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 100
        camera.simdPosition = simd_float3(0, mid.y + reach * 0.25, reach * 1.5)
        camera.look(at: SCNVector3(0, mid.y, 0))
        scene.rootNode.addChildNode(camera)
        view.pointOfView = camera

        container.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 20)))

        holder?.scnView = view
        DispatchQueue.main.async { onLoaded?(true) }   // never mutate @State during view building
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
