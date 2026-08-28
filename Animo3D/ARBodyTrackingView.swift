//
//  ARBodyTrackingView.swift
//  Animo3D
//
//  Apple's native ARKit live body tracking (approach A).
//  ARBodyTrackingConfiguration streams a live 3D skeleton, and the 91 joints are drawn as small spheres.
//  Only supported on A12 and newer physical devices; the Simulator and the iPhone X (A11) show an unsupported message.
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
                        Text("Point the camera at a full body — the green joints follow in real time")
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
                    Text("ARKit body tracking isn't supported on this device")
                        .font(.headline)
                    Text("Requires a physical device with an A12 chip or later (iPhone XS and newer).\nIt cannot run in the Simulator.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
        .navigationTitle("ARKit Body Tracking")
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

            // The skeleton root follows the body anchor; each joint is positioned by its model transform relative to that root
            bodyRoot?.transform = Transform(matrix: bodyAnchor.transform)
            for (i, t) in transforms.enumerated() where i < joints.count {
                joints[i].transform = Transform(matrix: t)
            }
        }
    }
}
