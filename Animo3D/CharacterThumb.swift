//
//  CharacterThumb.swift
//  Animo3D
//
//  Character 3D thumbnail. The actual rendering and caching live in ThumbRenderer (globally serial + three-tier cache).
//
//  The tile is the dance card's stage, in one of the same five keys - see `CardBackdrop`. It used
//  to be its own thing: a system `tint` at 0.25 over `secondarySystemBackground`, which in light
//  mode is a pale card. Three things went wrong with that. Next to the dance grid, which is a dark
//  lit stage, the character grid read as a different app. A character rendered on transparent black
//  sat on pale mint as a cut-out with nothing under its feet - the exact fault the dance cards were
//  rebuilt to fix. And white-on-`ultraThinMaterial` "DANCE" over a pale pink card is white on
//  near-white, which is why the badge kept being restyled and kept being illegible.
//

import SwiftUI

/// Character thumbnail view: prefers the cache, and renders in the background when there is no hit.
struct CharacterThumbView: View {
    let characterKey: String
    /// Which of `CardBackdrop`'s keys this tile is lit in. The caller passes its index in the grid,
    /// so a screenful cycles through the five the same way the dance grid does.
    var style: Int = 0
    @State private var image: UIImage?
    @State private var failed = false

    private var accent: Color { CardBackdrop.accent(for: style) }

    var body: some View {
        ZStack {
            CardBackdrop(style: style)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(10)
            } else if failed {
                // Never spin forever: a missing asset has to read as "unavailable", not "still loading".
                Image(systemName: "person.crop.square.badge.questionmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                ProgressView().tint(.white)
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
    /// See `CharacterThumbView.style`.
    var style: Int = 0

    private var accent: Color { CardBackdrop.accent(for: style) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                CharacterThumbView(characterKey: characterKey, style: style)
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)

                // Light, and low: the backdrop already ends in a darkened floor, so this is only
                // insurance for a render whose feet happen to fall where the badge sits.
                LinearGradient(colors: [.clear, .black.opacity(0.28)],
                               startPoint: .init(x: 0.5, y: 0.6), endPoint: .bottom)

                // The badge is the card's one piece of colour that is not light: a solid accent
                // disc against the dark floor, rather than a pale pill hoping to be seen.
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .frame(width: 20, height: 20)
                        .background(accent, in: Circle())
                        .shadow(color: accent.opacity(0.5), radius: 5, y: 2)

                    Text("DANCE")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .tracking(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.32), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            Text(name)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, 4)
        }
    }
}
