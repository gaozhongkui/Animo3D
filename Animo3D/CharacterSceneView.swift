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

    enum BackgroundType: String, CaseIterable {
        case studio, sky
    }

    let scene = SCNScene()
    private(set) var boneNodes: [String: SCNNode] = [:]
    private(set) var characterRoot: SCNNode?
    private(set) var cameraNode: SCNNode?
    private(set) var isLoaded = false
    private(set) var modelHeight: Float = 0   // 角色单位高度（AR 缩放用）
    private(set) var scheme: BoneScheme = .mixamo   // 骨骼命名方案（Mixamo / VRM）
    var isVRM: Bool { boneNodes["J_Bip_C_Hips"] != nil }   // VRoid 用完整动画 JSON 回放
    var groundEnabled = false   // 仅表演大画面开启地面+俯视;缩略图/小卡片关闭
    var contactShadowOnly = false   // 详情页:只加脚下接触阴影(给着地感),不加深色地板
    var portraitMode = false    // 静态展示(缩略图/角色详情):摆 A-pose,避开 SceneKit 在 T 绑定姿势下的蒙皮塌陷
    private var lightsAdded = false

    @Published var backgroundType: BackgroundType = .studio {
        didSet { updateBackgroundAndGround() }
    }

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
        if portraitMode { applyPortraitPose() }
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
        setupGround(root)
        updateBackgroundAndGround()
        isLoaded = true
        print("[Character] 加载成功，发现 \(found.count) 根 Mixamo 骨骼")
        return found.sorted()
    }

    func updateBackgroundAndGround() {
        var fog: UIColor
        switch backgroundType {
        case .studio:
            scene.background.contents = CharacterSceneView.studioBackdrop()
            fog = UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1)   // = 背景底色,地平线无缝
        case .sky:
            if let skyImage = UIImage(named: "sky_park") {
                scene.background.contents = skyImage
            } else {
                scene.background.contents = CharacterSceneView.skyBackdrop()
            }
            fog = UIColor(red: 0.82, green: 0.88, blue: 0.95, alpha: 1)   // = 天空地平线色
        }
        // 雾:地面远处渐隐到背景色 → 地面与背景无缝融合,产生纵深与着地感(仅表演大画面开)
        if groundEnabled {
            let h = max(modelHeight, 1)
            scene.fogColor = fog
            scene.fogStartDistance = CGFloat(h * 2.2)
            scene.fogEndDistance = CGFloat(h * 6.5)
            scene.fogDensityExponent = 1.5
        } else {
            scene.fogEndDistance = 0
        }
        if let root = characterRoot {
            setupGround(root)
        }
    }

    private var floorNode: SCNNode?
    private var contactShadow: SCNNode?
    private(set) var feetY: Float = 0   // 脚底世界 Y(特效地面定位用)

    /// 地面：可见的地板(带轻微反射) + 脚下始终可见的柔和接触阴影,消除"悬空"感。
    private func setupGround(_ root: SCNNode) {
        guard groundEnabled || contactShadowOnly else {
            floorNode?.removeFromParentNode(); floorNode = nil
            contactShadow?.removeFromParentNode(); contactShadow = nil
            return
        }
        // 脚底世界 Y + 水平范围
        var minY = Float.greatestFiniteMagnitude
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [Float(a.x), Float(b.x)] { for y in [Float(a.y), Float(b.y)] { for z in [Float(a.z), Float(b.z)] {
                let w = node.simdConvertPosition(simd_float3(x, y, z), to: nil)
                minY = min(minY, w.y)
                minX = min(minX, w.x); maxX = max(maxX, w.x)
                minZ = min(minZ, w.z); maxZ = max(maxZ, w.z)
            }}}
        }
        guard minY.isFinite else { return }
        feetY = minY
        let cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2
        let footSpan = max(maxX - minX, 0.001)

        // 地板：比背景底色略亮 + 轻微反射，形成清晰的"地面"参照
        floorNode?.removeFromParentNode()
        let floor = SCNFloor()
        if backgroundType == .sky {
            // 天空模式：只保留倒影，材质彻底透明且不捕捉光照，避免出现白色层
            floor.reflectivity = 0.5
            floor.firstMaterial?.diffuse.contents = UIColor.clear
            floor.firstMaterial?.lightingModel = .constant
        } else {
            // 恢复原始舞台模式：深色反射地板
            floor.reflectivity = 0.16
            floor.firstMaterial?.diffuse.contents = UIColor(red: 0.13, green: 0.13, blue: 0.18, alpha: 1)
            floor.firstMaterial?.lightingModel = .physicallyBased
        }
        floor.firstMaterial?.roughness.contents = 0.82
        let node = SCNNode(geometry: floor)
        node.simdPosition = simd_float3(0, minY, 0)
        scene.rootNode.addChildNode(node)
        floorNode = node

        // 脚下柔和接触阴影(始终可见,即使方向光阴影渲染不到也有"着地"线索)
        contactShadow?.removeFromParentNode()
        let blob = SCNPlane(width: CGFloat(footSpan * 2.4), height: CGFloat(footSpan * 1.5))
        let bm = blob.firstMaterial!
        bm.diffuse.contents = Self.contactShadowImage()
        bm.lightingModel = .constant
        bm.isDoubleSided = true
        bm.writesToDepthBuffer = false
        let bnode = SCNNode(geometry: blob)
        bnode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)          // 平铺在地面上
        bnode.simdPosition = simd_float3(cx, minY + 0.003, cz)
        bnode.renderingOrder = 1                                     // 画在地板之上
        scene.rootNode.addChildNode(bnode)
        contactShadow = bnode
    }

    /// 柔和圆形接触阴影贴图：中心黑、边缘透明。
    private static func contactShadowImage() -> UIImage {
        let s = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: s).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawRadialGradient(g,
                startCenter: CGPoint(x: s.width/2, y: s.height/2), startRadius: 0,
                endCenter: CGPoint(x: s.width/2, y: s.height/2), endRadius: s.width/2, options: [])
        }
    }

    /// 用骨骼位置算出角色实际的 上/左/前 三轴，强制把根节点旋正为 Y-up、面朝 +Z。
    /// 不依赖 USD 的 upAxis 元数据（该模型元数据不可信）。
    /// 静态肖像姿势：仅 VRM(VRoid) 需要。手臂放下成 A 字,并轻微扰动躯干链,
    /// 让 SceneKit 重新求值蒙皮——否则这些骨架在 T 绑定姿势下会塌陷(手臂成片、头飘)。
    /// 跳舞路径不调用(重定向器会自行驱动骨骼)。
    private func applyPortraitPose() {
        guard boneNodes["J_Bip_C_Hips"] != nil else { return }   // 仅 VRM
        rotateBone(scheme.leftArm,  angle:  1.0, axis: simd_float3(0, 0, 1))
        rotateBone(scheme.rightArm, angle: -1.0, axis: simd_float3(0, 0, 1))
        rotateBone(scheme.spine,    angle: 0.03, axis: simd_float3(1, 0, 0))
        rotateBone(scheme.head,     angle: 0.03, axis: simd_float3(1, 0, 0))
    }

    private func rotateBone(_ name: String, angle: Float, axis: simd_float3) {
        guard let b = boneNodes[name] else { return }
        b.simdOrientation = simd_mul(b.simdOrientation, simd_quatf(angle: angle, axis: axis))
    }

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
        cam.camera?.zNear = Double(height) * 0.01
        cam.camera?.zFar = Double(height) * 50
        if groundEnabled {
            // 表演大画面：略微俯视,让脚下地面与影子可见,像站在地上
            cam.camera?.fieldOfView = 60
            cam.position = SCNVector3(center.x, foot.y + height * 1.05, center.z + height * 2.15)
            cam.look(at: SCNVector3(center.x, foot.y + height * 0.5, center.z))
        } else {
            // 缩略图/卡片：正面平视,居中框全身
            cam.camera?.fieldOfView = 62
            cam.position = SCNVector3(center.x, center.y, center.z + height * 1.9)
            cam.look(at: center)
        }
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
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)

        // 从上前方打下的方向光，投出随动作变化的真实软阴影
        let sun = SCNNode()
        let l = SCNLight(); l.type = .directional
        l.castsShadow = true
        l.shadowMode = .forward            // 通用可靠(含模拟器),阴影落在地板上可见
        l.shadowColor = UIColor(white: 0, alpha: 0.5)
        l.shadowRadius = 6
        l.shadowSampleCount = 16
        sun.light = l
        sun.eulerAngles = SCNVector3(-Float.pi / 2.2, Float.pi / 12, 0)  // 更接近正上方 → 影子聚在脚下
        scene.rootNode.addChildNode(sun)
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
        view.antialiasingMode = DeviceTier.antialiasing   // 低端降抗锯齿,减卡顿
        view.allowsCameraControl = true
        // 受控转盘：绕角色水平环绕 + 限制俯仰角,避免转到贴地平视把地面光环糊到脸上
        let cc = view.defaultCameraController
        cc.interactionMode = .orbitTurntable
        cc.inertiaEnabled = true
        cc.minimumVerticalAngle = -6      // 不能太仰
        cc.maximumVerticalAngle = 55      // 不能俯到贴地看地面特效
        cc.target = SCNVector3(0, controller.feetY + controller.modelHeight * 0.5, 0)
        // 根据背景类型设置背景与地面
        controller.updateBackgroundAndGround()
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
    static func studioBackdrop() -> UIImage {
        let size = CGSize(width: 300, height: 650)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            // 竖向渐变：顶部冷紫 → 底部深色(=fogColor 0.06,0.06,0.10,与雾/地面无缝)
            let colors = [UIColor(red: 0.17, green: 0.15, blue: 0.28, alpha: 1).cgColor,
                          UIColor(red: 0.11, green: 0.10, blue: 0.17, alpha: 1).cgColor,
                          UIColor(red: 0.06, green: 0.06, blue: 0.10, alpha: 1).cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.5, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            // 地平线辉光：中下部一片暖紫柔光，像舞台后墙的聚光,给纵深
            let halo = [UIColor(red: 0.42, green: 0.33, blue: 0.7, alpha: 0.38).cgColor, UIColor.clear.cgColor]
            let hg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: halo as CFArray, locations: [0, 1])!
            c.drawRadialGradient(hg,
                                 startCenter: CGPoint(x: size.width/2, y: size.height*0.64), startRadius: 0,
                                 endCenter: CGPoint(x: size.width/2, y: size.height*0.64), endRadius: size.width*0.85,
                                 options: [])
            // 底部中心一圈柔光，像脚下舞台聚光
            let glow = [UIColor.white.withAlphaComponent(0.10).cgColor, UIColor.clear.cgColor]
            let rg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glow as CFArray, locations: [0, 1])!
            c.drawRadialGradient(rg,
                                 startCenter: CGPoint(x: size.width/2, y: size.height*0.78), startRadius: 0,
                                 endCenter: CGPoint(x: size.width/2, y: size.height*0.78), endRadius: size.width*0.7,
                                 options: [])
        }
    }

    /// 兜底程序化天空背景
    static func skyBackdrop() -> UIImage {
        let size = CGSize(width: 400, height: 800)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let colors = [UIColor(red: 0.45, green: 0.65, blue: 0.88, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor,
                          UIColor.white.cgColor]
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                               locations: [0, 0.6, 1])!
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
    }
}
