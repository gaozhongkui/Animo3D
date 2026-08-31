//
//  CharacterThumb.swift
//  Animo3D
//
//  Character 3D thumbnail. The actual rendering and caching live in ThumbRenderer (globally serial + three-tier cache).
//

import SwiftUI

/// The asset file name for a character.
///
/// The catalog is authoritative - it states the real file (`char_vroid_4.usdz` vs `char_Remy.scn`).
/// Guessing it from the key (`key.contains("vroid")`) breaks the moment a non-VRoid usdz is added.
/// A copy inside the bundle still wins, so a locally dropped-in model can be tested without the network.
func characterModelFile(_ key: String) -> String {
    if let file = RemoteAssets.shared.character(key)?.file { return file }
    // Catalog not loaded (it is seeded from the bundle, so this is unexpected), or a model dropped
    // in locally under its bare key for testing.
    for ext in ["scn", "usdz"] {
        if Bundle.main.url(forResource: key, withExtension: ext) != nil { return "\(key).\(ext)" }
    }
    return "char_\(key).scn"
}

/// Character thumbnail view: prefers the cache, and renders in the background when there is no hit.
struct CharacterThumbView: View {
    let characterKey: String
    var tint: Color = .accentColor
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.05)],
                           startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
            } else if failed {
                // Never spin forever: a missing asset has to read as "unavailable", not "still loading".
                Image(systemName: "person.crop.square.badge.questionmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(tint.opacity(0.55))
            } else {
                ProgressView().tint(tint)
            }
        }
        .task(id: characterKey) {
            if let m = ThumbRenderer.shared.memoryCached(character: characterKey) {
                image = m; failed = false; return
            }
            image = nil
            failed = false
            let img = await ThumbRenderer.shared.characterImage(characterKey)
            guard !Task.isCancelled else { return }
            image = img
            failed = (img == nil)
        }
    }
}
