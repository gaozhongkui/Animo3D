import Combine

/// Only catalog delivery is controlled; timing and cancellation use the production SplashView.
@MainActor
final class RemoteAssets: ObservableObject {
    static let shared = RemoteAssets()
    enum State { case loading, ready, unavailable }
    @Published var state = State.loading
    func start() {}
}
