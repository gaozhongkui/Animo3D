//
//  ARBodyTrackingView.swift
//  Animo3D
//
//  苹果原生 ARKit 实时人体追踪（方案 A）。
//  用 ARBodyTrackingConfiguration 实时输出 3D 骨架，用小球把 91 个关节点画出来。
//  仅支持 A12 及以上真机；模拟器 / iPhone X(A11) 会显示不支持提示。
//

import SwiftUI
import RealityKit
import ARKit

struct ARBodyEntryView: View {
    var body: some View {
        Group {
            if ARBodyTrackingConfiguration.isSupported {
                ARBodyContainer()
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        Text("对准一个完整的人，绿色骨点会实时跟随")
                            .font(.footnote)
                            .padding(8)
                            .background(.black.opacity(0.5), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.top, 8)
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("此设备不支持 ARKit 人体追踪")
                        .font(.headline)
                    Text("需要 A12 及以上芯片的真机（iPhone XS 及以后），且无法在模拟器运行。\n你的 iPhone X 为 A11，不支持此功能。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .navigationTitle("ARKit 人体追踪")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ARBodyContainer: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        context.coordinator.arView = arView
        arView.session.delegate = context.coordinator
        let config = ARBodyTrackingConfiguration()
        arView.session.run(config)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    final class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        private var bodyRoot: AnchorEntity?
        private var joints: [ModelEntity] = []

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard let bodyAnchor = anchors.compactMap({ $0 as? ARBodyAnchor }).first else { return }
            let transforms = bodyAnchor.skeleton.jointModelTransforms

            if bodyRoot == nil, let arView {
                let root = AnchorEntity()
                arView.scene.addAnchor(root)
                bodyRoot = root
                let mat = SimpleMaterial(color: .green, isMetallic: false)
                for _ in transforms {
                    let sphere = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [mat])
                    root.addChild(sphere)
                    joints.append(sphere)
                }
            }

            // 骨架根跟随身体锚点；各关节点用相对根的模型变换定位
            bodyRoot?.transform = Transform(matrix: bodyAnchor.transform)
            for (i, t) in transforms.enumerated() where i < joints.count {
                joints[i].transform = Transform(matrix: t)
            }
        }
    }
}
