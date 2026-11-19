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

            if loops {
                TimelineView(.periodic(from: .now, by: Self.interval)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate / Self.interval)
                    // Both the offset and the modulus count the whole loop, not the frames that have
                    // arrived so far. Counting arrivals meant that every time one landed the cadence
                    // was re-dealt underneath the playhead - at three frames the card played 0,1,2,
                    // at four it played a different order from a different phase - so frames the eye
                    // had already seen flashed back. The frames themselves still stream in; a slot
                    // the renderer has not reached yet holds on the newest one instead of jumping.
                    let i = (step + abs(dance.hashValue % ThumbRenderer.loopFrames)) % ThumbRenderer.loopFrames
                    Image(uiImage: frames[min(i, frames.count - 1)]).resizable().scaledToFit()
                }
            } else if let image {
                // Showing static signature frame exclusively when loops is false.
                // This prevents the semi-transparent overlay "ghosting" or "artifacting"
                // between the static and moving layers during animation transitions.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: image != nil)
        .animation(.none, value: loops) // Disable container interpolation which bleeds transparency.
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: character + "|" + dance + "|\(style)|\(animated)") {
            // Step 1: Render and display static 3D pose cover image first (one by one across cards)
            if let m = ThumbRenderer.shared.memoryCached(character: character, dance: dance, style: style) {
                image = m
            } else {
                image = nil
                frames = []
                let img = await ThumbRenderer.shared.danceCard(character: character, dance: dance, style: style)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    image = img
                }
            }

            guard animated, DeviceTier.allowsLiveDanceCards else { return }

            // Step 2: Yield so all visible cards in the viewport get their static covers rendered FIRST
            // before any cell starts queuing 10 consecutive loop frame renders.
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            // Step 3: Stream loop frames incrementally
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
