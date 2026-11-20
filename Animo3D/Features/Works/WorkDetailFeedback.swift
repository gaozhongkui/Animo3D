import SwiftUI

extension View {
    func workDetailFeedback(model: WorkDetailModel) -> some View {
        modifier(WorkDetailFeedback(model: model))
    }
}

private struct WorkDetailFeedback: ViewModifier {
    @ObservedObject var model: WorkDetailModel

    func body(content: Content) -> some View {
        let issueID = model.issue?.id
        return content.alert(LocalizedStringKey(model.issue?.title ?? ""), isPresented: Binding(
            get: { model.issue != nil },
            set: { presented in
                guard !presented, let issueID else { return }
                Task { @MainActor in
                    if model.issue?.id == issueID { model.issue = nil }
                }
            }
        )) {
            Button("Retry") { model.retry() }
            Button("Cancel", role: .cancel) { model.issue = nil }
        } message: {
            Text(LocalizedStringKey(model.issue?.message ?? ""))
        }
    }
}
