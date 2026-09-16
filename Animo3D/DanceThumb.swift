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
    /// Whether the card moves while it is on screen. The dance step turns this on; the home screen
    /// leaves it off, where a wall of moving cards would compete with the thing it is selling.
    var animated: Bool = false

    @State private var image: UIImage?
    @State private var frames: [UIImage] = []
    @State private var onScreen = false

    /// How long one frame of the loop is held. Derived from the renderer's own window so the two
    /// cannot drift: it drew `loopFrames` frames spanning `loopWindow` seconds, and this plays them
    /// back over the same span.
    private static var interval: Double {
        Double(ThumbRenderer.loopWindow) / Double(ThumbRenderer.loopFrames)
    }

    /// Enough of the loop has arrived, and this card is on screen to see it.
    private var loops: Bool { animated && onScreen && frames.count >= 3 }

    var body: some View {
        ZStack {
            CardBackdrop(style: style)

            // The still is what the card is until the loop has enough of itself to move, and what
            // it stays if this card is not meant to move at all. It fades out as the loop comes in
            // rather than being drawn under it: both images are cut out around the figure, so one
            // over the other is two characters at once - which is exactly what it looked like.
            if let image {
                Image(uiImage: image).resizable().scaledToFit().opacity(loops ? 0 : 1)
            } else {
                ProgressView().tint(.white).scaleEffect(1.2)
            }

            if loops {
                TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
                    // Offset per dance, so a screenful of cards is not marching in lockstep.
                    let i = (step + abs(dance.hashValue % frames.count)) % frames.count
                    Image(uiImage: frames[i]).resizable().scaledToFit()
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: loops)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: character + "|" + dance + "|\(style)|\(animated)") {
            // A memory hit displays synchronously: no loading flash and no disk access, which is
            // the path that matters while the list scrolls.
            if let m = ThumbRenderer.shared.memoryCached(character: character, dance: dance, style: style) {
                image = m
            } else {
                image = nil
                frames = []
                let img = await ThumbRenderer.shared.danceCard(character: character, dance: dance, style: style)
                guard !Task.isCancelled else { return }
                image = img
            }

            guard animated, DeviceTier.allowsLiveDanceCards else { return }

            // One frame at a time, and the task is cancelled the moment this cell is recycled - so a
            // card the user scrolled straight past costs one or two drawings, not ten. They are
            // handed over as they arrive, which is why the loop starts at three rather than waiting
            // for the set.
            var built: [UIImage] = []
            for i in 0..<ThumbRenderer.loopFrames {
                guard !Task.isCancelled else { return }
                guard let f = await ThumbRenderer.shared.danceLoopFrame(
                    character: character, dance: dance, style: style, index: i) else { continue }
                built.append(f)
                guard !Task.isCancelled else { return }
                frames = built
            }
        }
    }
}
