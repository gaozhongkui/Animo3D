import SwiftUI

extension View {
    func videoImportFeedback(source: VideoImportStore) -> some View {
        modifier(VideoImportFeedback(source: source))
    }
}

private struct VideoImportFeedback: ViewModifier {
    @ObservedObject var source: VideoImportStore

    func body(content: Content) -> some View {
        content.alert("Could not import video", isPresented: Binding(
            get: { source.errorMessage != nil },
            set: { if !$0 { source.errorMessage = nil } }
        )) {
            Button("Retry") { source.retry() }
            Button("Cancel", role: .cancel) { source.errorMessage = nil }
        } message: {
            Text(LocalizedStringKey(source.errorMessage ?? ""))
        }
    }
}
