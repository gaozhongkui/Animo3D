//
//  DanceThumb.swift
//  Animo3D
//
//  为每支舞渲染一张"角色摆出该舞蹈代表姿势"的缩略图。
//  实际渲染/缓存都在 ThumbRenderer 里(全局串行 + 复用模型 + 三级缓存)。
//

import SwiftUI

/// 舞蹈姿势缩略图视图。
struct DanceThumbView: View {
    let model: String   // 含扩展名
    let dance: String
    var style: Int = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CardBackdrop(style: style)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white).scaleEffect(1.2)   // 渲染中 loading
            }
        }
        .task(id: model + "|" + dance) {   // 角色(model)或舞蹈变化都重渲染
            // 内存命中就同步显示,不闪 loading、不碰磁盘(列表滑动时这条路径最关键)
            if let m = ThumbRenderer.shared.memoryCached(model: model, dance: dance) {
                image = m; return
            }
            image = nil
            let img = await ThumbRenderer.shared.danceImage(model: model, dance: dance)
            guard !Task.isCancelled else { return }
            image = img
        }
    }
}
