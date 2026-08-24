//
//  CharacterSceneView.swift
//  Animo3D
//
//  SceneKit 3D 角色容器：加载 rigged 模型、定位骨骼节点，
//  停掉自带动画（改由 BlazePose 驱动），并按模型尺寸自动取景。
//

import SwiftUI
import SceneKit
import Combine

final class CharacterSceneController: ObservableObject {

    let scene = SCNScene()
    private(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // 角色单位高度（AR 缩放用）
    private(set) var scheme: BoneScheme = .mixamo   // 骨骼命名方案（Mixamo / VRM）
    private var lightsAdded = false

    /// 把角色根节点挂回本控制器的屏幕场景（从 AR 切回时用）。
    func reattachToScreenScene() {
        guard let root = characterRoot else { return }
        if root.parent !== scene.rootNode {
            root.removeFromParentNode()
            scene.rootNode.addChildNode(root)
        }
    }

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

        // 复用同一场景：先移除旧角色，避免每次切换都累积角色/内存（真机切几次会卡死的根因）
        characterRoot?.removeFromParentNode()
        boneNodes.removeAll()
        isLoaded = false

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
        // 按骨骼命名判定方案：VRoid(VRM) 用 J_Bip_ 前缀，否则按 Mixamo
        scheme = (boneNodes["J_Bip_C_Hips"] != nil) ? .vrm : .mixamo
        print("[Character] 骨骼方案: \(boneNodes["J_Bip_C_Hips"] != nil ? "VRM" : "Mixamo")")
        normalizeOrientation(root)
        setupFrontCamera()

        // 兜底高度计算：骨骼识别失败（如 Tripo 静态网格无 Mixamo 骨骼）时，
        // 遍历所有几何体、把各自局部包围盒的 8 个角点转换到世界坐标求真实 AABB。
        // 直接用 root.boundingBox 不可靠：不一定含子节点，也没算导入缩放。
        if modelHeight <= 0.01 {
            modelHeight = worldBoundingHeight(root)
            print(String(format: "[Character] 使用包围盒兜底高度=%.3f", modelHeight))
        }

        if !lightsAdded { addLights(); lightsAdded = true }
        isLoaded = true
        print("[Character] 加载成功，发现 \(found.count) 根 Mixamo 骨骼")
        return found.sorted()
    }

    /// 用骨骼位置算出角色实际的 上/左/前 三轴，强制把根节点旋正为 Y-up、面朝 +Z。
    /// 不依赖 USD 的 upAxis 元数据（该模型元数据不可信）。
    private func normalizeOrientation(_ root: SCNNode) {
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let lsh = boneNodes[scheme.leftShoulder]?.simdWorldPosition,
              let rsh = boneNodes[scheme.rightShoulder]?.simdWorldPosition else { return }
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
        guard let hips = boneNodes[scheme.hips]?.simdWorldPosition,
              let head = boneNodes[scheme.head]?.simdWorldPosition,
              let foot = boneNodes[scheme.leftFoot]?.simdWorldPosition else { return }
        let height = abs(head.y - foot.y)
        guard height > 0 else { return }
        modelHeight = height
        let center = SCNVector3(hips.x, (head.y + foot.y) / 2, hips.z)
        print(String(format: "[Cam] head.y=%.2f foot.y=%.2f height=%.2f center=(%.2f,%.2f,%.2f)",
                     head.y, foot.y, height, center.x, center.y, center.z))

        // 复用已有相机（避免每次切换新增相机节点）
        let cam = cameraNode ?? {
            let n = SCNNode(); n.camera = SCNCamera()
            scene.rootNode.addChildNode(n); cameraNode = n; return n
        }()
        cam.camera?.fieldOfView = 62
        cam.camera?.zNear = Double(height) * 0.01
        cam.camera?.zFar = Double(height) * 50
        // 站在角色正前方(+Z)，拉远留出头顶/两侧余量（抬手/伸腿不被裁切）
        cam.position = SCNVector3(center.x, center.y, center.z + height * 1.9)
        cam.look(at: center)
    }

    /// 世界坐标下遍历整棵子树的几何体，求 AABB 的 Y 向高度（米）。
    /// 处理任意嵌套变换与导入缩放，适用于无骨骼的静态模型。
    private func worldBoundingHeight(_ root: SCNNode) -> Float {
        var lo = simd_float3(repeating: .greatestFiniteMagnitude)
        var hi = simd_float3(repeating: -.greatestFiniteMagnitude)
        var any = false
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            let xs = [Float(a.x), Float(b.x)]
            let ys = [Float(a.y), Float(b.y)]
            let zs = [Float(a.z), Float(b.z)]
            for x in xs { for y in ys { for z in zs {
                let w = node.simdConvertPosition(simd_float3(x, y, z), to: nil)
                lo = simd_min(lo, w); hi = simd_max(hi, w); any = true
            }}}
        }
        return any ? (hi.y - lo.y) : 0
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
    var onAttach: (() -> Void)? = nil
    var holder: SceneHolder? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var framed = false }

    func makeUIView(context: Context) -> SCNView {
        // 从 AR 切回时，把角色挂回屏幕场景，并让重定向重新采样
        controller.reattachToScreenScene()
        onAttach?()
        let view = SCNView()
        view.scene = controller.scene
        view.allowsCameraControl = true
        // 渐变"舞台"背景，比纯色好看（AR 模式用相机画面，不受影响）
        controller.scene.background.contents = Self.studioBackdrop()
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = true
        view.rendersContinuously = true      // 持续渲染，避免切换后画面冻结
        view.isPlaying = true
        if let cam = controller.cameraNode { view.pointOfView = cam }
        holder?.scnView = view
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        if let cam = controller.cameraNode { uiView.pointOfView = cam }
    }

    /// 生成一张竖向渐变 + 底部聚光的"舞台"背景图。
    private static func studioBackdrop() -> UIImage {
        let size = CGSize(width: 300, height: 650)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // 竖向渐变：顶部偏冷紫 → 底部近黑
            let colors = [UIColor(red: 0.22, green: 0.20, blue: 0.32, alpha: 1).cgColor,
                          UIColor(red: 0.11, green: 0.10, blue: 0.16, alpha: 1).cgColor,
                          UIColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.55, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // 底部中心一圈柔光，像舞台聚光
            let glow = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
            let rg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow as CFArray, locations: [0, 1])!
            c.drawRadialGradient(rg,
                                 startCenter: CGPoint(x: size.width/2, y: size.height*0.78), startRadius: 0,
                                 endCenter: CGPoint(x: size.width/2, y: size.height*0.78), endRadius: size.width*0.7,
                                 options: [])
        }
    }
}
