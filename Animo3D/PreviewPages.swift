//
//  PreviewPages.swift
//  Animo3D
//
//  放大预览页：角色可旋转/缩放查看,舞蹈全屏实时跳动,并可一键投射到 AR。
//  卡片右上角"放大"按钮进入。
//

import SwiftUI
import SceneKit
import Combine

/// 卡片右上角的"放大"按钮。
struct ZoomButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// 可旋转/缩放查看的场景（3D 模式）。两指捏合缩放,单指旋转。
struct SceneOrbitView: UIViewRepresentable {
    let controller: CharacterSceneController
    var animated: Bool = false

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = controller.scene
        v.backgroundColor = .clear
        v.allowsCameraControl = true          // 手势旋转 + 两指缩放
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = DeviceTier.antialiasing   // 4x MSAA 太重,按机型分级
        v.rendersContinuously = animated
        v.isPlaying = animated
        if let cam = controller.cameraNode { v.pointOfView = cam }
        return v
    }
    func updateUIView(_ v: SCNView, context: Context) {
        if let cam = controller.cameraNode { v.pointOfView = cam }
    }
}

/// 持有一个用于预览的角色控制器,可选驱动一支舞;供 3D 与 AR 共用,避免切换时重载。
final class PreviewStage: ObservableObject {
    let controller = CharacterSceneController()
    @Published private(set) var ready = false
    private var retargeter: PoseRetargeter?
    private var player: MocapPlayer?
    private var loaded = false
    var animated: Bool { player != nil }

    /// 模型与舞蹈数据都在后台解析,主线程只挂节点 —— 否则打开放大预览页会明显卡一下。
    @MainActor
    func ensure(model: String, dance: String?) async {
        guard !loaded else { return }
        loaded = true
        if dance == nil { controller.portraitMode = true }   // 角色静态详情:摆 A-pose
        let scene = await Task.detached(priority: .userInitiated) {
            CharacterSceneController.loadSceneFile(named: model, warmUp: true)
        }.value
        guard let scene else { return }
        controller.install(scene)
        ready = true
        guard let dance else { return }
        let rt = PoseRetargeter(controller: controller); retargeter = rt
        let clip = await Task.detached(priority: .userInitiated) {
            Bundle.main.url(forResource: dance, withExtension: "json").flatMap { MocapClip.load($0) }
        }.value
        if let clip {
            let p = MocapPlayer(frames: clip.frames, retargeter: rt)
            player = p; p.start()
        }
    }
    func resetRetarget() { retargeter?.resetCapture() }
    func stop() { player?.stop() }
}

/// 预览页公用外壳：3D/AR 切换 + 关闭 + 标题。
private struct PreviewShell: View {
    let name: String
    let style: Int
    let model: String
    let dance: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stage = PreviewStage()
    @State private var arMode = false

    var body: some View {
        ZStack(alignment: .top) {
            CardBackdrop(style: style).ignoresSafeArea()   // 沿用卡片装饰背景

            Group {
                if arMode {
                    ARCharacterView(controller: stage.controller, onAttach: { stage.resetRetarget() })
                } else {
                    SceneOrbitView(controller: stage.controller, animated: dance != nil)
                }
            }
            .id(arMode)
            .ignoresSafeArea()

            // 顶部：关闭 + 3D/AR 切换
            HStack {
                CircleButton(system: "xmark") { stage.stop(); dismiss() }
                Spacer()
                Picker("", selection: $arMode) { Text("3D").tag(false); Text("AR").tag(true) }
                    .pickerStyle(.segmented).frame(width: 120)
            }
            .padding(.horizontal, 16).padding(.top, 8)

            VStack {
                Spacer()
                Text(name).font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(arMode ? "移动手机寻找地面放置" : "拖动旋转 · 两指缩放")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .padding(.bottom, 30)
            }.frame(maxWidth: .infinity)
        }
        .overlay {
            if !stage.ready {
                ProgressView().tint(.white).scaleEffect(1.3)
            }
        }
        .task { await stage.ensure(model: model, dance: dance) }
        .onDisappear { stage.stop() }
    }
}

/// 角色放大页（可旋转/缩放 + AR 放置）。
struct CharacterPreviewPage: View {
    let key: String
    let name: String
    var style: Int = 0
    var body: some View {
        PreviewShell(name: name, style: style, model: characterModelFile(key), dance: nil)
    }
}

/// 舞蹈放大页（全屏实时跳动,可旋转/缩放 + AR 投射）。
struct DancePreviewPage: View {
    let dance: String
    let name: String
    var style: Int = 0
    var model: String = "vroid_preview.usdz"
    var body: some View {
        PreviewShell(name: name, style: style, model: model, dance: dance)
    }
}
