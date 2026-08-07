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
    private(set) var cameraNode: SCNNode?
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

        // 收集骨骼节点，同时彻底移除自带烘焙动画（否则动画会自己播放、抢占骨骼控制权）
        var found: [String] = []
        var animCount = 0
        root.removeAllAnimations()
        root.enumerateChildNodes { node, _ in
            animCount += node.animationKeys.count
            for key in node.animationKeys { node.removeAnimation(forKey: key) }
            node.removeAllAnimations()
            if let name = node.name {
                boneNodes[name] = node
                if name.hasPrefix("mixamorig") { found.append(name) }
            }
        }
        print("[Character] 清除自带动画 keys=\(animCount)")
        normalizeOrientation(root)
        setupFrontCamera()

        addLights()
        isLoaded = true
        print("[Character] 加载成功，发现 \(found.count) 根 Mixamo 骨骼")
        return found.sorted()
    }

    /// 用骨骼位置算出角色实际的 上/左/前 三轴，强制把根节点旋正为 Y-up、面朝 +Z。
    /// 不依赖 USD 的 upAxis 元数据（该模型元数据不可信）。
    private func normalizeOrientation(_ root: SCNNode) {
        guard let hips = boneNodes["mixamorig_Hips"]?.simdWorldPosition,
              let head = boneNodes["mixamorig_Head"]?.simdWorldPosition,
              let lsh = boneNodes["mixamorig_LeftShoulder"]?.simdWorldPosition,
              let rsh = boneNodes["mixamorig_RightShoulder"]?.simdWorldPosition else { return }
        let up = simd_normalize(head - hips)            // 角色的“上”
        let right0 = simd_normalize(lsh - rsh)           // 角色左肩→，作为 +X
        let forward = simd_normalize(simd_cross(right0, up))
        let right = simd_normalize(simd_cross(up, forward))
        // m: 恒等基 → 模型基；取逆即把模型旋正到恒等基
        let m = simd_float3x3(right, up, forward)
        root.simdOrientation = simd_quatf(m).inverse
    }

    /// 用骨骼位置摆一个固定正面全身相机（比包围盒可靠，不受骨架外延干扰）。
    private func setupFrontCamera() {
        guard let hips = boneNodes["mixamorig_Hips"]?.simdWorldPosition,
              let head = boneNodes["mixamorig_Head"]?.simdWorldPosition,
              let foot = boneNodes["mixamorig_LeftFoot"]?.simdWorldPosition else { return }
        let height = abs(head.y - foot.y)
        guard height > 0 else { return }
        let center = SCNVector3(hips.x, (head.y + foot.y) / 2, hips.z)
        print(String(format: "[Cam] head.y=%.2f foot.y=%.2f height=%.2f center=(%.2f,%.2f,%.2f)",
                     head.y, foot.y, height, center.x, center.y, center.z))

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.fieldOfView = 55
        cam.camera?.zNear = Double(height) * 0.01
        cam.camera?.zFar = Double(height) * 50
        // 站在角色正前方(+Z)，正对中心
        cam.position = SCNVector3(center.x, center.y, center.z + height * 1.3)
        cam.look(at: center)
        cameraNode = cam
        scene.rootNode.addChildNode(cam)
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
        guard !context.coordinator.framed,
              controller.isLoaded,
              let cam = controller.cameraNode else { return }
        context.coordinator.framed = true
        uiView.pointOfView = cam
    }

    private func scene_addCamera(_ cam: SCNNode) {
        controller.scene.rootNode.addChildNode(cam)
    }
}
