//
//  CharacterThumb.swift
//  Animo3D
//
//  角色 3D 缩略图。实际渲染/缓存在 ThumbRenderer 里(全局串行 + 三级缓存)。
//

import SwiftUI

/// 按角色 key 找到实际模型文件（.scn 或 .usdz）。
func characterModelFile(_ key: String) -> String {
    for ext in ["scn", "usdz"] {
        if Bundle.main.url(forResource: key, withExtension: ext) != nil { return "\(key).\(ext)" }
    }
    return "\(key).scn"
}

/// 角色缩略图视图：优先用缓存，没有则后台渲染。
struct CharacterThumbView: View {
    let characterKey: String
    var tint: Color = .accentColor
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else {
                ProgressView().tint(tint)
            }
        }
        .task(id: characterKey) {
            if let m = ThumbRenderer.shared.memoryCached(character: characterKey) {
                image = m; return
            }
            image = nil
            let img = await ThumbRenderer.shared.characterImage(characterKey)
            guard !Task.isCancelled else { return }
            image = img
        }
    }
}
