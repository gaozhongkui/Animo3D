import SwiftUI

// Unrelated network and analytics dependencies are not started by recording tests.
enum SketchfabClient {
    static let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-models")
}

enum TrackEvent { case workSaved, exportFinished }
enum Track {
    static func log(_ event: TrackEvent, _ parameters: [String: Any] = [:]) {}
    static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

struct WorkDetailView: View {
    let url: URL
    var justSaved: Bool
    var onClose: () -> Void
    var body: some View { Text("Saved recording") }
}
