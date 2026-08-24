//
//  SwitchStressView.swift — 调试：用现有 Mixamo 舞蹈驱动 VRoid(VRM) 模型。
//

import SwiftUI

struct SwitchStressView: View {
    private let controller = CharacterSceneController()
    @State private var retargeter: PoseRetargeter?
    @State private var player: MocapPlayer?
    @State private var status = "…"

    var body: some View {
        VStack(spacing: 4) {
            CharacterSceneView(controller: controller).frame(maxHeight: .infinity)
            Text(status).font(.caption)
        }
        .onAppear(perform: setup)
    }

    private func setup() {
        guard retargeter == nil else { return }
        let bones = controller.loadModel(named: "vroid_preview.usdz")
        let rt = PoseRetargeter(controller: controller)
        retargeter = rt
        guard let url = Bundle.main.url(forResource: "Macarena_Dance", withExtension: "json"),
              let clip = MocapClip.load(url) else {
            status = "找不到舞蹈"; return
        }
        let p = MocapPlayer(frames: clip.frames, retargeter: rt)
        player = p
        p.start()
        status = "VRoid + Macarena · 骨骼\(bones.count) · 帧\(clip.frames.count)"
    }
}
