//
//  ModelPreviewView.swift
//  Animo3D
//
//  In-app SceneKit 3D preview: loads a downloaded USDZ and forces its materials opaque at runtime
//  (which fixes Sketchfab spec-gloss models looking translucent in Quick Look), and can be rotated by finger.
//  Compared with "re-export the USDZ + Quick Look", it uses far less memory: one scene is loaded, nothing is re-encoded,
//  and no extra Quick Look service is launched - safer on 3GB-class devices like the iPhone X (it avoids the out-of-memory reboot).
//

import SwiftUI
import SceneKit

struct ModelPreviewView: View {
    let url: URL
    let title: String
    var onOpenAR: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var scene: SCNScene?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let scene {
                SceneView(scene: scene, options: [.autoenablesDefaultLighting, .allowsCameraControl])
                    .ignoresSafeArea()
            } else if failed {
                Text("Couldn't load this model").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }

            // Top bar: close + title + (optional) AR
            HStack {
                CircleButton(system: "xmark") { dismiss() }
                Spacer()
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let onOpenAR {
                    CircleButton(system: "arkit", action: onOpenAR)
                } else {
                    Color.clear.frame(width: 38, height: 38)
                }
            }
            .padding(.horizontal, 12).padding(.top, 6)
        }
        .task { load() }
    }

    private func load() {
        guard scene == nil else { return }
        guard let s = try? SCNScene(url: url) else { failed = true; return }

        // Force opacity at runtime (cheap, no re-export, no memory spike)
        s.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { m in
                m.transparency = 1
                m.transparent.contents = nil
                m.transparencyMode = .default
                m.writesToDepthBuffer = true
            }
        }

        // Place a camera that frames the whole model
        let (minB, maxB) = s.rootNode.boundingBox
        let c = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
        let sz = max(maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)
        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.zNear = 0.01
        cam.camera?.zFar = Double(sz) * 50
        cam.position = SCNVector3(c.x, c.y, c.z + sz * 2.0)
        cam.look(at: c)
        s.rootNode.addChildNode(cam)
        s.rootNode.addChildNode({
            let n = SCNNode(); n.light = SCNLight(); n.light?.type = .ambient
            n.light?.intensity = 300; return n
        }())
        scene = s
    }
}
