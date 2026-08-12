//
//  AnimatedModelView.swift
//  Animo3D
//
//  加载"带预制动画的角色 .scn"并循环播放（验证 Mixamo 预制动画质量）。
//

import SwiftUI
import SceneKit

struct AnimatedModelView: UIViewRepresentable {
    let resource: String
    let ext: String

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .init(white: 0.15, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.isPlaying = true
        view.rendersContinuously = true

        let scene = SCNScene()
        view.scene = scene

        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let loaded = try? SCNScene(url: url, options: nil) else { return view }

        let root = loaded.rootNode
        scene.rootNode.addChildNode(root)

        // 显式循环播放所有动画
        var animCount = 0
        root.enumerateChildNodes { node, _ in
            for key in node.animationKeys {
                if let p = node.animationPlayer(forKey: key) {
                    p.animation.repeatCount = .greatestFiniteMagnitude
                    p.play(); animCount += 1
                }
            }
        }
        print("[Anim] 播放动画数: \(animCount)")

        // 手动正面相机：按包围盒摆正、拉够远
        let (minV, maxV) = root.boundingBox
        let c = root.convertPosition(SCNVector3((minV.x+maxV.x)/2, (minV.y+maxV.y)/2, (minV.z+maxV.z)/2),
                                     to: scene.rootNode)
        let size = max(maxV.x-minV.x, max(maxV.y-minV.y, maxV.z-minV.z))
        print(String(format: "[Anim] bbox size=%.2f center=(%.2f,%.2f,%.2f)", size, c.x, c.y, c.z))
        let cam = SCNNode(); cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 55
        cam.camera?.zNear = Double(size) * 0.01
        cam.camera?.zFar = Double(size) * 50
        cam.position = SCNVector3(c.x, c.y, c.z + size * 2.0)
        cam.look(at: c)
        scene.rootNode.addChildNode(cam)
        view.pointOfView = cam

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.intensity = 600; scene.rootNode.addChildNode(amb)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

struct PresetAnimTestView: View {
    var body: some View {
        AnimatedModelView(resource: "ybot_hiphop", ext: "scn")
            .ignoresSafeArea()
    }
}
