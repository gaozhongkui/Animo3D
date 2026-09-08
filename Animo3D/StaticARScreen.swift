//
//  StaticARScreen.swift
//  Animo3D
//
//  The AR screen for a community model: place it, move it, record it, share it.
//
//  This is what "View in AR" opens now. It used to hand the file to `QLPreviewController`, Apple's
//  own AR Quick Look - which places a model well but is a closed surface: no way to add a shutter
//  button, and no access to its frames, so nothing could be recorded. The whole point of the
//  community feed is finding something worth filming, and that dead-ended at a preview.
//
//  Recording goes through the same `SceneViewRecorder` the dance stage uses, so a clip from here
//  and a clip from there are the same kind of artefact: same capture path, same burned-in
//  watermark, same place in My Works.
//

import SwiftUI

struct StaticARScreen: View {
    let url: URL
    let title: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = SceneViewRecorder()
    @StateObject private var holder = SceneHolder()
    @ObservedObject private var pro = ProStore.shared

    @State private var placed = false
    /// Read once, at init: writing the flag must not make the panel disappear mid-render.
    @State private var showCoach = !ARCoachView.hasBeenSeen
    /// True while Apple's scanning overlay owns the screen. Everything of the app's own hides -
    /// the overlay is full-screen, and two sets of instructions at once is worse than either.
    @State private var coaching = true
    @State private var trackingHint: String?
    @State private var finished: FinishedWork?
    @State private var showMiss = false
    @State private var missTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            StaticARView(url: url,
                         onPlaced: { placed = true },
                         onPlacementMissed: { flashMiss() },
                         onTapped: { retireCoach() },
                         onCoaching: { coaching = $0 },
                         onTrackingHint: { trackingHint = $0 },
                         holder: holder)
                .ignoresSafeArea()

            // Own guidance only once Apple's is done: it covers scanning, this covers the tap.
            if !placed && showCoach && !coaching {
                ARCoachView()
                    .transition(.opacity)
            }

            // Why tracking is unhealthy, when it is. Suppressed while the overlay is up, because
            // the overlay says the same things better.
            if let trackingHint, !coaching, !placed {
                VStack {
                    Spacer()
                    Text(trackingHint)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.horizontal, 32)
                        .padding(.bottom, 150)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if showMiss {
                VStack {
                    Spacer()
                    Text("Point at the floor, then tap")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .padding(.bottom, 190)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    CircleButton(system: "xmark") {
                        if recorder.isRecording { recorder.stop { _ in } }
                        dismiss()
                    }
                    // Also hidden under the scanning overlay, which draws its own full-screen UI.
                    .opacity(recorder.isRecording || coaching ? 0 : 1)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 8)

                Spacer()

                // Always present, the way the dance stage's shutter is. It used to appear only
                // once `placed` was true, on the reasoning that filming an empty room is not worth
                // a button - which was wrong twice over: it makes the control vanish exactly when
                // placement is not working (no plane found, a room too dark, a community USDZ that
                // failed to open), leaving a screen with no shutter and no explanation for why;
                // and the user can see the viewfinder, so whether there is anything worth filming
                // is their call, not this screen's.
                recordButton
                    .padding(.bottom, 34)
            }
        }
        .fullScreenCover(item: $finished) { work in
            WorkDetailView(url: work.url, justSaved: true) { finished = nil }
        }
        .onDisappear {
            missTask?.cancel()
            if recorder.isRecording { recorder.stop { _ in } }
        }
    }

    private var recordButton: some View {
        Button {
            HapticManager.medium()
            if recorder.isRecording {
                recorder.stop { out in
                    guard let out, let saved = WorksStore.shared.add(from: out) else { return }
                    HapticManager.success()
                    finished = FinishedWork(url: saved)
                }
            } else if let v = holder.scnView {
                recorder.start(view: v, watermark: pro.isPro ? nil : "Livo 3D")
            }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: recorder.isRecording ? 7 : 30, style: .continuous)
                    .fill(Color.red)
                    .frame(width: recorder.isRecording ? 30 : 60,
                           height: recorder.isRecording ? 30 : 60)
            }
            .frame(width: 80, height: 80)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recorder.isRecording)
        }
    }

    /// The panel is instruction, and one tap is proof it was read. It also does not come back in
    /// later sessions - `ARCoachView.hasBeenSeen` is per install.
    private func retireCoach() {
        ARCoachView.hasBeenSeen = true
        guard showCoach else { return }
        withAnimation(.easeOut(duration: 0.25)) { showCoach = false }
    }

    /// Say something when a tap found no floor. Silence was the previous answer, and it left the
    /// user tapping a screen that never responded.
    private func flashMiss() {
        HapticManager.light()
        missTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { showMiss = true }
        missTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showMiss = false }
        }
    }
}
