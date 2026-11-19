//
//  PoseOverlayView.swift
//  Animo3D
//
//  Overlays BlazePose's 33 landmarks and skeleton lines on top of the video.
//

import SwiftUI

struct PoseOverlayView: View {
    let landmarks: [NormalizedLandmarkLite]
    /// The rectangle the video actually occupies on screen (including the letterbox offset).
    let videoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard !landmarks.isEmpty, videoRect.width > 0 else { return }

            func point(_ i: Int) -> CGPoint {
                let lm = landmarks[i]
                return CGPoint(x: videoRect.origin.x + lm.x * videoRect.width,
                               y: videoRect.origin.y + lm.y * videoRect.height)
            }

            // Lines
            var path = Path()
            for (a, b) in PoseSkeleton.connections where a < landmarks.count && b < landmarks.count {
                path.move(to: point(a))
                path.addLine(to: point(b))
            }
            context.stroke(path, with: .color(.green), lineWidth: 3)

            // Landmarks
            for i in landmarks.indices {
                let p = point(i)
                let r: CGFloat = 4
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                     width: r * 2, height: r * 2)),
                             with: .color(.red))
            }
        }
        .allowsHitTesting(false)
    }
}
