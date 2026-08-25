//
//  AnimClipTestView.swift
//  Animo3D
//
//  【实验】完整骨骼动画验证:加载 Mixamo 角色(x_bot) + 套一段完整动作剪辑(走路),
//  用 SceneKit 原生 animationPlayer 播放全身动画。对比现在的 8 骨简化驱动。
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
            print("[AnimTest] 找不到角色 x_bot.usdz"); return v
        }

        // 加载动画剪辑,把每个 animationPlayer 套到角色同名骨骼节点
        var applied = 0
        if let animURL = Bundle.main.url(forResource: "walk_full", withExtension: "usdz"),
           let animScene = try? SCNScene(url: animURL, options: nil) {
            animScene.rootNode.enumerateChildNodes { n, _ in
                guard let nm = n.name, !n.animationKeys.isEmpty else { return }
                guard let target = charScene.rootNode.childNode(withName: nm, recursively: true) else { return }
                for key in n.animationKeys {
                    if let p = n.animationPlayer(forKey: key) {
                        p.animation.repeatCount = .greatestFiniteMagnitude   // 循环
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
                Text("完整骨骼动画 · X Bot 走路").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("SceneKit 原生播放 · 拖动可转视角").font(.caption).foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 30)
            }.frame(maxWidth: .infinity)
            CircleButton(system: "xmark") { onClose() }.padding(16)
        }
    }
}
