//
//  FullscreenPreviewScreen.swift
//  Animo3D
//
//  The community model's own 3D preview, filling the screen.
//
//  The detail page shows the same embed in a 400pt box, which is enough to tell what a model is and
//  not enough to look at one - the turntable ends up smaller than the buttons under it. This is the
//  same Sketchfab embed with nothing else on top of it.
//
//  It reloads rather than handing the inline web view over. A `WKWebView` has one superview at a
//  time, so sharing the instance between the page and this screen means reparenting it on every
//  transition and leaving whichever side lost it blank. The reload costs a couple of seconds, which
//  is what the spinner is for, and it starts the viewer from its default framing - which is the
//  right place to start looking anyway.
//

import SwiftUI

struct FullscreenPreviewScreen: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    /// Fades once the model has had time to appear. The gesture hint is worth showing, but only
    /// until it has been read - it sits over the model.
    @State private var showHint = true

    var body: some View {
        ZStack {
            // Black, not the system background: this is a viewer, and a light page around a dark
            // 3D viewport reads as an unloaded box.
            Color.black.ignoresSafeArea()

            ZStack {
                ProgressView().tint(.white)
                // The embed is transparent until it draws, so the spinner behind it shows through
                // rather than being covered by a blank white page.
                WebView(url: url)
            }
            .ignoresSafeArea()

            // A scrim under the top row. The model's own backdrop is whatever its author chose -
            // it came out mid-grey here, and white is just as likely - so neither the title nor the
            // close button can be relied on to be legible against it.
            VStack {
                LinearGradient(colors: [.black.opacity(0.45), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                    Spacer(minLength: 12)
                    CircleButton(system: "xmark") { dismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if showHint {
                    Text("Drag to rotate, pinch to zoom")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(.bottom, 28)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeOut(duration: 0.4)) { showHint = false }
        }
    }
}
