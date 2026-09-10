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

/// The character tile, shared by the Characters grid and Home's "Featured Dancers" grid.
///
/// Home used to draw its own: a 32pt radius against the 20pt used everywhere else, a fixed 180pt
/// height that made the tile a different shape on every screen width, and a white "DANCE" pill on
/// bare `.ultraThinMaterial` - which, over these light thumbnails, was white on near-white. One
/// card, one shape, one scrim.
struct CharacterCard: View {
    let name: String
    let characterKey: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                CharacterThumbView(characterKey: characterKey, tint: tint)
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)

                // What makes the badge readable at all: the thumbnails are pale, so the label needs
                // its own darkness to sit on rather than borrowing the render's.
                LinearGradient(colors: [.clear, .black.opacity(0.45)],
                               startPoint: .center, endPoint: .bottom)

                HStack(spacing: 7) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                        .frame(width: 22, height: 22)
                        .background(.white, in: Circle())

                    Text("Dance")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(10)
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 4)

            Text(name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 4)
        }
    }
}
