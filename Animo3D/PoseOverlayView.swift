//
//  PoseOverlayView.swift
//  Animo3D
//
//  在视频上叠加 BlazePose 的 33 个关节点和骨架连线。
//

import SwiftUI

struct PoseOverlayView: View {
    let landmarks: [NormalizedLandmarkLite]
    /// 视频在屏幕上真正显示的矩形(含黑边偏移)。
    let videoRect: CGRect

    var body: some View {
        Canvas { context, _ in
            guard !landmarks.isEmpty, videoRect.width > 0 else { return }

            func point(_ i: Int) -> CGPoint {
                let lm = landmarks[i]
                return CGPoint(x: videoRect.origin.x + lm.x * videoRect.width,
                               y: videoRect.origin.y + lm.y * videoRect.height)
            }

            // 连线
            var path = Path()
            for (a, b) in PoseSkeleton.connections where a < landmarks.count && b < landmarks.count {
                path.move(to: point(a))
                path.addLine(to: point(b))
            }
            context.stroke(path, with: .color(.green), lineWidth: 3)

            // 关节点
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
