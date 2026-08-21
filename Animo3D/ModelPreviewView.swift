//
//  ModelPreviewView.swift
//  Animo3D
//
//  App 内自绘的 SceneKit 3D 预览：加载下载来的 USDZ，运行时把材质强制不透明
//  （解决 Sketchfab spec-gloss 模型在 Quick Look 里半透明的问题），可手指旋转查看。
//  相比"重导出 USDZ + Quick Look"，内存占用小很多：只加载一份场景、不重新编码、
//  不额外拉起 Quick Look 服务——对 iPhone X 这类 3GB 老设备更安全（避免内存顶爆重启）。
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
                Text("无法加载该模型").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }

            // 顶部栏：关闭 + 标题 +（可选）AR
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .foregroundStyle(.white).padding(10)
                        .background(.black.opacity(0.5), in: Circle())
                }
                Spacer()
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if let onOpenAR {
                    Button { onOpenAR() } label: {
                        Image(systemName: "arkit").font(.body.weight(.semibold))
                            .foregroundStyle(.white).padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12)
        }
        .task { load() }
    }

    private func load() {
        guard scene == nil else { return }
        guard let s = try? SCNScene(url: url) else { failed = true; return }

        // 运行时强制不透明（廉价，无重导出、无内存尖峰）
        s.rootNode.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { m in
                m.transparency = 1
                m.transparent.contents = nil
                m.transparencyMode = .default
                m.writesToDepthBuffer = true
            }
        }

        // 摆一个框住整体的相机
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
