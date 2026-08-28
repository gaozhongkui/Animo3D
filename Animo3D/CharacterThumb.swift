//
//  CharacterThumb.swift
//  Animo3D
//
//  Character 3D thumbnail. The actual rendering and caching live in ThumbRenderer (globally serial + three-tier cache).
//

import SwiftUI

/// Finds the actual model file (.scn or .usdz) for a character key.
func characterModelFile(_ key: String) -> String {
    for ext in ["scn", "usdz"] {
        if Bundle.main.url(forResource: key, withExtension: ext) != nil { return "\(key).\(ext)" }
    }
    return "\(key).scn"
}

/// Character thumbnail view: prefers the cache, and renders in the background when there is no hit.
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
