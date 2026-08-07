//
//  CharacterSceneView.swift
//  Animo3D
//
//  SceneKit 3D 角色容器：加载 rigged 模型、定位骨骼节点，
//  停掉自带动画（改由 BlazePose 驱动），并按模型尺寸自动取景。
//

import SwiftUI
import SceneKit

final class CharacterSceneController {

    let scene = SCNScene()
    private(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var isLoaded = false

    /// 从 App 包加载模型（.usdz/.scn/.dae）。返回发现的 Mixamo 骨骼名。
    @discardableResult
    func loadModel(named filename: String) -> [String] {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: base,
                                        withExtension: ext.isEmpty ? nil : ext) else {
            print("[Character] 找不到模型文件: \(filename)")
            return []
        }
        guard let loaded = try? SCNScene(url: url, options: [.convertToYUp: false]) else {
            print("[Character] 模型加载失败: \(url.lastPathComponent)")
            return []
        }

        // 不要 clone：克隆带蒙皮的节点会破坏 SCNSkinner 的骨骼引用（iOS 16 上尤其明显，
        // 表现为网格塌陷/拉成三角片）。直接使用加载出来的根节点。
        let root = loaded.rootNode
        scene.rootNode.addChildNode(root)
        characterRoot = root

        // 收集骨骼节点，同时移除自带动画（否则会覆盖我们写入的骨骼旋转）
        var found: [String] = []
        root.enumerateChildNodes { node, _ in
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
            }
        }

        addLights()
        isLoaded = true
        print("[Character] 加载成功，发现 \(found.count) 根 Mixamo 骨骼")
        return found.sorted()
    }

    private func addLights() {
        let key = SCNNode()
        key.light = SCNLight(); key.light?.type = .omni
        key.position = SCNVector3(0, 100, 100)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)
    }
}

struct CharacterSceneView: UIViewRepresentable {
    let controller: CharacterSceneController

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var framed = false }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.allowsCameraControl = true
        view.backgroundColor = .init(white: 0.15, alpha: 1)
        view.autoenablesDefaultLighting = true
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // 模型加载完成后，用 SceneKit 内置取景自动把整个角色装进画面（只做一次）
        guard !context.coordinator.framed,
              controller.isLoaded,
              let root = controller.characterRoot else { return }
        context.coordinator.framed = true
        DispatchQueue.main.async {
            uiView.defaultCameraController.frameNodes([root])
        }
    }
}
