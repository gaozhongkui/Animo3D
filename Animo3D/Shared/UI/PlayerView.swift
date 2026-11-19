//
//  PlayerView.swift
//  Animo3D
//
//  Wraps an AVPlayerLayer and reports back the rectangle the video actually occupies (videoRect),
//  so the skeleton overlay can align exactly with the video (accounting for aspect-fit letterboxing).
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
