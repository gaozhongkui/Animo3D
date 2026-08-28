//
//  DanceThumb.swift
//  Animo3D
//
//  Renders one thumbnail per dance, showing the character striking that dance's signature pose.
//  The actual rendering and caching live in ThumbRenderer (globally serial + model reuse + three-tier cache).
//

import SwiftUI

/// Dance pose thumbnail view.
struct DanceThumbView: View {
    let model: String   // Includes the extension
    let dance: String
    var style: Int = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CardBackdrop(style: style)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white).scaleEffect(1.2)   // Loading while rendering
            }
        }
        .task(id: model + "|" + dance) {   // Re-render whenever the character (model) or the dance changes
            // On a memory-cache hit, display synchronously: no loading flash and no disk access (this path matters most while the list scrolls)
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
