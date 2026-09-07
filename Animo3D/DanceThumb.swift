//
//  DanceThumb.swift
//  Animo3D
//
//  One card per dance, showing the chosen character striking that dance's signature pose. Rendered
//  on device by ThumbRenderer: memory -> disk -> one global serial offscreen render, against a
//  single reused model.
//
//  The heavy lifting this replaced: every card used to build its own controller in `Task.detached`
//  and parse the model again, so fast scrolling had a dozen 4-60MB parses in flight and `.task`
//  cancellation never reached them. What makes it affordable now is that the models are texture
//  compressed (largest 7.6MB) and the dance step already prewarms the one the stage will need.
//

import SwiftUI

struct DanceCardView: View {
    let character: String
    let dance: String
    var style: Int = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CardBackdrop(style: style)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white).scaleEffect(1.2)
            }
        }
        .task(id: character + "|" + dance) {
            // A memory hit displays synchronously: no loading flash and no disk access, which is
            // the path that matters while the list scrolls.
            if let m = ThumbRenderer.shared.memoryCached(character: character, dance: dance) {
                image = m; return
            }
            image = nil
            let img = await ThumbRenderer.shared.danceCard(character: character, dance: dance)
            guard !Task.isCancelled else { return }
            image = img
        }
    }
}
