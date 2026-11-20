import SwiftUI
import AVKit

struct WorkDetailView: View {
    let url: URL
    var justSaved = false
    var onClose: () -> Void

    @StateObject private var model: WorkDetailModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var showDeleteConfirm = false
    @State private var showSavedBanner = false

    init(url: URL, justSaved: Bool = false, onClose: @escaping () -> Void) {
        self.url = url
        self.justSaved = justSaved
        self.onClose = onClose
        _model = StateObject(wrappedValue: WorkDetailModel(url: url))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: model.player).ignoresSafeArea()

            HStack {
                CircleButton(system: "xmark") {
                    model.deactivate()
                    onClose()
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if showSavedBanner {
                Label("Saved to My Creations", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 72)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            VStack {
                Spacer()
                HStack(spacing: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 30) {
                    shareButton
                    gifButton
                    actionButton("trash", "Delete", tint: .red) { showDeleteConfirm = true }
                }
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            isVisible = true
            if scenePhase == .active { model.activate() }
        }
        .onDisappear {
            isVisible = false
            model.deactivate()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, isVisible { model.activate() }
            else { model.deactivate() }
        }
        .onChange(of: model.deleted) { if $0 { onClose() } }
        .task {
            guard justSaved else { return }
            withAnimation(.spring(response: 0.4)) { showSavedBanner = true }
            do { try await Task.sleep(nanoseconds: 3_500_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { showSavedBanner = false }
        }
        .sheet(item: $model.share, onDismiss: model.shareDismissed) { request in
            ShareSheet(items: [request.item])
        }
        .confirmationDialog("Delete this creation?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        }
        .workDetailFeedback(model: model)
    }

    private var shareButton: some View {
        actionButton("square.and.arrow.up", "Share", busy: model.preparingShare) {
            HapticManager.light()
            Track.log(.workShared)
            model.prepareShare()
        }
        .disabled(model.preparingShare || model.preparingGIF)
    }

    private var gifButton: some View {
        Button {
            HapticManager.light()
            if model.preparingGIF { model.cancelGIF() }
            else { model.prepareGIF() }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: model.preparingGIF ? "xmark.circle" : "photo.stack")
                    .font(.title2)
                    .frame(height: 26)
                Text(model.preparingGIF ? "\(Int(model.gifProgress * 100))%" : "GIF")
                    .font(.caption)
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
        .disabled(model.preparingShare)
        .accessibilityLabel(model.preparingGIF ? Text("Cancel GIF export") : Text(verbatim: "GIF"))
    }

    private func actionButton(
        _ icon: String,
        _ title: LocalizedStringKey,
        tint: Color = .white,
        busy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Image(systemName: icon).font(.title2).opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(.white) }
                }
                .frame(height: 26)
                Text(title).font(.caption)
            }
            .foregroundStyle(tint)
            .frame(width: 64, height: 60)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
