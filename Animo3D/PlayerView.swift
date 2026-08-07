//
//  PlayerView.swift
//  Animo3D
//
//  包一层 AVPlayerLayer，并把视频真正显示的矩形区域(videoRect)回传，
//  好让骨架叠加层跟视频严格对齐(考虑 aspect-fit 的黑边)。
//

import SwiftUI
import AVFoundation

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onVideoRectChange: ((CGRect) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.videoGravity = .resizeAspect
        onVideoRectChange?(playerLayer.videoRect)
    }
}

struct PlayerView: UIViewRepresentable {
    let player: AVPlayer
    @Binding var videoRect: CGRect

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.onVideoRectChange = { rect in
            DispatchQueue.main.async { self.videoRect = rect }
        }
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}
