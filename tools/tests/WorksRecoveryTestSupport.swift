import Foundation

nonisolated enum SketchfabClient {
    static let modelsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-models")
}

enum Track {
    enum Event { case workDeleted, workShared }
    static func log(_ event: Event, _ parameters: [String: Any] = [:]) {}
}

actor WorkTestGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        opened = true
        let pending = waiting
        waiting.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor WorkDecodeProbe {
    private(set) var count = 0
    private(set) var active = 0
    private(set) var maximum = 0
    private(set) var usedMainThread = false
    func begin(onMainThread: Bool = false) -> Int {
        count += 1
        active += 1
        maximum = max(maximum, active)
        usedMainThread = usedMainThread || onMainThread
        return count
    }
    func finish() { active -= 1 }
}

nonisolated final class DeleteFailingFileManager: FileManager, @unchecked Sendable {
    var shouldFail = true
    override func removeItem(at url: URL) throws {
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

nonisolated func makeOwnedTestGIF(in directory: URL) throws -> ExportedGIF {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(UUID().uuidString + ".gif")
    let bytes = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
    try bytes.write(to: url)
    return ExportedGIF(temporaryURL: url)
}
