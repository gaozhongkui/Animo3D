import SwiftUI

/// All recording entry points share the same recovery actions and saved-video presentation.
private struct RecordingFeedback: ViewModifier {
    @ObservedObject var output: RecordingOutput

    func body(content: Content) -> some View {
        content
            .alert(
                LocalizedStringKey(output.issue?.title ?? "Recording failed"),
                isPresented: Binding(
                    get: { output.issue != nil },
                    set: { if !$0 { output.issue = nil } }
                ),
                presenting: output.issue
            ) { _ in
                if output.canRetry {
                    Button("Retry") {
                        Task { await output.retry() }
                    }
                }
                if output.canKeepOriginal {
                    Button("Keep Original Video") { output.keepOriginal() }
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { issue in
                Text(verbatim: issue.message)
            }
            .fullScreenCover(item: $output.finished) { work in
                WorkDetailView(url: work.url, justSaved: true) { output.finished = nil }
            }
            .onChange(of: output.finished?.id) { id in
                if id != nil { HapticManager.success() }
            }
    }
}

extension View {
    func recordingFeedback(output: RecordingOutput) -> some View {
        modifier(RecordingFeedback(output: output))
    }
}
