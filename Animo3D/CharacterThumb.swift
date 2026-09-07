//
//  CharacterThumb.swift
//  Animo3D
//
//  Character 3D thumbnail. The actual rendering and caching live in ThumbRenderer (globally serial + three-tier cache).
//

import SwiftUI

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
