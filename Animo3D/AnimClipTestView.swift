//
//  AnimClipTestView.swift
//  Animo3D
//
//  [Experiment] Full skeletal animation check: load a Mixamo character (x_bot) and apply a complete motion clip (walking),
//  played through SceneKit's native animationPlayer. Compare it against the current simplified 8-bone drive.
//

import SwiftUI
import SceneKit

struct AnimClipSceneView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.backgroundColor = UIColor(white: 0.09, alpha: 1)
        v.rendersContinuously = true
        v.isPlaying = true

        guard let charURL = Bundle.main.url(forResource: "x_bot", withExtension: "usdz"),
              let charScene = try? SCNScene(url: charURL, options: nil) else {
            print("[AnimTest] character x_bot.usdz not found"); return v
        }

        // Load the animation clip and attach each animationPlayer to the character's bone node of the same name
        var applied = 0
        if let animURL = Bundle.main.url(forResource: "walk_full", withExtension: "usdz"),
           let animScene = try? SCNScene(url: animURL, options: nil) {
            animScene.rootNode.enumerateChildNodes { n, _ in
                guard let nm = n.name, !n.animationKeys.isEmpty else { return }
                guard let target = charScene.rootNode.childNode(withName: nm, recursively: true) else { return }
                for key in n.animationKeys {
                    if let p = n.animationPlayer(forKey: key) {
                        p.animation.repeatCount = .greatestFiniteMagnitude   // Loop
                        target.addAnimationPlayer(p, forKey: key)
                        p.play()
                        applied += 1
                    }
                }
            }
        }
        print("[AnimTest] applied players = \(applied)")

        v.scene = charScene
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.position = SCNVector3(0, 0.95, 2.9)
        cam.look(at: SCNVector3(0, 0.9, 0))
        charScene.rootNode.addChildNode(cam)
        v.pointOfView = cam
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {}
}

struct AnimClipTestPage: View {
    var onClose: () -> Void
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            AnimClipSceneView().ignoresSafeArea()
            VStack {
                Spacer()
                Text("Full Skeletal Animation · X Bot Walking").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("Native SceneKit playback · drag to orbit").font(.caption).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 30)
            }.frame(maxWidth: .infinity)
            CircleButton(system: "xmark") { onClose() }.padding(16)
        }
    }
}
