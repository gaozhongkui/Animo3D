//
//  RemoteAssets.swift
//  Animo3D
//
//  The asset catalog and the download cache behind it.
//
//  index.json (schema 2) is the only asset config in the project, and it covers exactly what has to
//  travel: character models, dance clips, and the character card art. Dance cards are not in here -
//  they are rendered on device from the built-in character plus the dance's own clip. Everything
//  bundled is bundled because it is fixed and small: the four music tracks, plus the one character
//  and one dance that let a first launch perform with no download.
//
//  How it got here, so none of it comes back:
//
//  - **`baseUrl` + a bucket-relative path per file.** Every entry used to carry its own absolute
//    URL, and the index that actually shipped had `[YOUR_SUPABASE_URL]` in all of them. One host in
//    one place, and the paths mirror the bucket's own folders.
//  - **No signed URLs.** A token in the URL expires and a shipped build cannot recover when it
//    does. The bucket is public; none of these files are secret.
//  - **Bundle and cache are keyed by the bare file name**, never a URL or a path. A file can move
//    between folders in the bucket without invalidating one cached download, and a bundled copy
//    always wins the lookup - which is the whole mechanism behind `Res/builtin`.
//  - **`schema` is enforced and `revision` orders catalogs.** An index this build does not
//    understand is rejected rather than decoded into a shape where every field is nil.
//  - **No music, no sizes, no digests.** Music ships in `Res/music`, where the bundled copy won the
//    lookup anyway, so listing it only added 14MB of pointless upload. A declared size duplicated
//    Content-Length. Instead of a digest to keep in sync, a file that fails to parse is evicted and
//    fetched again - which is what actually recovers a truncated body or a stored error page.
//
//  Per-kind item types rather than one item with everything optional: a character without a model,
//  or a dance without a clip, is a broken catalog and should fail to decode.
//

import Foundation
import Combine

// MARK: - Catalog models

/// A bucket-relative path, e.g. "dances/mocap_Hip_Hop_Dancing.json". Its URL is `baseUrl + path`.
typealias AssetPath = String

extension String {
    /// The name the bundle and the disk cache use for this asset.
    var assetName: String { (self as NSString).lastPathComponent }
}

struct CharacterItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let model: AssetPath
    let thumb: AssetPath?
}

struct DanceItem: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let clip: AssetPath
    let duration: Double?
}

/// Which character and dance are expected to ship inside the app. Declared by the index and checked
/// against the bundle on load, rather than hand-written in Swift: the two constants that used to
/// live here had drifted from the files on disk, so the "built-in" default downloaded every time.
struct BuiltInSet: Decodable, Hashable {
    let character: String
    let dance: String
}

struct RemoteCatalog: Decodable {
    static let supportedSchema = 2

    let schema: Int
    /// Monotonic content version. A catalog is only replaced by one with a higher revision.
    let revision: Int
    let generated: String?
    let minAppVersion: String?
    /// Directory holding every path in this catalog. Must end in "/".
    let baseUrl: String
    let notice: String?
    let builtin: BuiltInSet?
    let characters: [CharacterItem]
    let dances: [DanceItem]
}

// MARK: - RemoteAssets

final class RemoteAssets: ObservableObject {
    static let shared = RemoteAssets()

    /// A plain public-bucket URL: no token, so nothing here expires.
    private static let indexBase = "https://dekbcnbakegjgbjxflxe.supabase.co/storage/v1/object/public/models/index.json"

    /// The index URL with a cache-buster, bucketed to five minutes.
    ///
    /// Supabase serves public objects through its CDN with `cache-control: max-age=3600`, so
    /// re-uploading index.json leaves clients on the previous catalog for up to an hour with no way
    /// to ask for the new one - measured: a fresh upload still answered with the old revision and
    /// `cf-cache-status: HIT`. Bucketing rather than using a raw timestamp keeps the request
    /// cacheable for everyone inside the same five minutes; the file is 7KB, so the trade is cheap.
    /// Asset objects keep the full hour: they are large and their contents are stable.
    private var indexURL: URL {
        let bucket = Int(Date().timeIntervalSince1970) / 300
        return URL(string: "\(Self.indexBase)?v=\(bucket)")!
    }

    @Published private(set) var characters: [CharacterItem] = []
    @Published private(set) var dances: [DanceItem] = []
    @Published private(set) var catalogSource: Source = .none
    @Published private(set) var state: State = .loading
    @Published private(set) var notice: String?
    @Published private(set) var progress: [String: Double] = [:]

    enum Source: String { case none, cache, network }

    /// What the UI should show. `.loading` covers the launch fetch; after `launchGrace` without a
    /// usable index it becomes `.unavailable`, so the home screen can say so instead of showing
    /// empty grids forever. Retries continue in the background either way.
    enum State: String { case loading, ready, unavailable }

    /// How long the launch fetch gets before the home screen shows its own loading state.
    static let launchGrace: TimeInterval = 20

    var activeDownloadProgress: Double? { progress.values.min() }

    /// The pair the index says is bundled; checked against the bundle in `apply`.
    private(set) var builtIn: BuiltInSet?

    private let lock = NSLock()
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var loadTask: Task<Void, Never>?
    private var catalog: RemoteCatalog?
    private var charById: [String: CharacterItem] = [:]
    private var danceById: [String: DanceItem] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = true
        return URLSession(configuration: c, delegate: self.downloader, delegateQueue: nil)
    }()

    private let downloader = Downloader()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteAssets")
    }
    private var catalogCacheURL: URL { cacheDir.appendingPathComponent("_index.json") }

    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // The last index answers instantly, so a returning user is never blocked on the network. The
        // launch fetch still runs and replaces it when the revision is newer.
        if let cat = decodeCatalog(try? Data(contentsOf: catalogCacheURL), from: "cache") {
            apply(cat, source: .cache)
        }
    }

    // MARK: - Catalog

    /// Kick off the launch fetch. Called once from the app entry point, so the index is in flight
    /// before the first screen is on display.
    func start() {
        guard loadTask == nil else { return }
        let deadline = Date().addingTimeInterval(Self.launchGrace)
        loadTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled {
                if await self.refresh() { return }
                attempt += 1
                if Date() >= deadline {
                    await MainActor.run { if self.catalog == nil { self.state = .unavailable } }
                }
                // Back off but keep trying, so it recovers on its own when connectivity returns.
                let delay = min(30, pow(2, Double(min(attempt, 5))))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Force another attempt (the home screen's retry button).
    func retry() {
        loadTask?.cancel()
        loadTask = nil
        if catalog == nil { state = .loading }
        start()
    }

    /// Fetch the index. Returns true once a usable catalog is in place.
    @discardableResult
    func refresh() async -> Bool {
        do {
            var request = URLRequest(url: indexURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await session.data(for: request)
            guard let cat = decodeCatalog(data, from: "network") else { return catalog != nil }
            guard cat.revision >= (catalog?.revision ?? -1) else {
                NSLog("[RemoteAssets] ignoring index revision %d, holding %d",
                      cat.revision, catalog?.revision ?? -1)
                return true
            }
            try? data.write(to: catalogCacheURL, options: .atomic)
            apply(cat, source: .network)
            return true
        } catch {
            NSLog("[RemoteAssets] index fetch failed (holding %@): %@",
                  catalogSource.rawValue, error.localizedDescription)
            // Without this the worst failure this app has is also its quietest: no index means
            // empty grids on every screen, and nothing anywhere says why.
            Track.log(.catalogFailed, ["reason": String(describing: type(of: error)),
                                       "holding": catalogSource.rawValue])
            return catalog != nil
        }
    }

    /// Decode and gate. A catalog whose schema this build does not know, or which demands a newer
    /// app, is discarded here rather than half-decoded into empty lists downstream.
    private func decodeCatalog(_ data: Data?, from origin: String) -> RemoteCatalog? {
        guard let data else { return nil }
        guard let cat = try? JSONDecoder().decode(RemoteCatalog.self, from: data) else {
            NSLog("[RemoteAssets] %@ index failed to decode", origin)
            return nil
        }
        guard cat.schema == RemoteCatalog.supportedSchema else {
            NSLog("[RemoteAssets] %@ index schema %d unsupported (this build reads %d)",
                  origin, cat.schema, RemoteCatalog.supportedSchema)
            return nil
        }
        guard cat.baseUrl.hasSuffix("/"), !cat.baseUrl.contains("["),
              URL(string: cat.baseUrl + "probe") != nil else {
            NSLog("[RemoteAssets] %@ index has an unusable baseUrl: %@", origin, cat.baseUrl)
            return nil
        }
        if let min = cat.minAppVersion,
           Self.appVersion.compare(min, options: .numeric) == .orderedAscending {
            NSLog("[RemoteAssets] %@ index needs app %@, this is %@", origin, min, Self.appVersion)
            return nil
        }
        return cat
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    private func apply(_ cat: RemoteCatalog, source: Source) {
        lock.lock()
        catalog = cat
        builtIn = cat.builtin
        charById = Dictionary(cat.characters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        danceById = Dictionary(cat.dances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()

        let publish = { [weak self] in
            guard let self else { return }
            self.characters = cat.characters
            self.dances = cat.dances
            self.notice = cat.notice
            self.catalogSource = source
            self.state = cat.characters.isEmpty || cat.dances.isEmpty ? .unavailable : .ready
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }

        NSLog("[RemoteAssets] %@ index rev=%d chars=%d dances=%d",
              source.rawValue, cat.revision, cat.characters.count, cat.dances.count)
        Track.log(.catalogLoaded, ["source": source.rawValue, "revision": cat.revision,
                                   "characters": cat.characters.count, "dances": cat.dances.count])
        // A declared built-in that is not actually in the bundle means every "no network needed"
        // path quietly downloads instead. Say so rather than letting it hide.
        if let b = cat.builtin {
            let paths = [cat.characters.first { $0.id == b.character }?.model,
                         cat.dances.first { $0.id == b.dance }?.clip].compactMap { $0 }
            for p in paths where bundleURL(for: p.assetName) == nil {
                NSLog("[RemoteAssets] index declares built-in %@ but it is not in the bundle", p)
            }
        }
    }

    func character(_ id: String) -> CharacterItem? { lock.lock(); defer { lock.unlock() }; return charById[id] }
    func dance(_ id: String) -> DanceItem? { lock.lock(); defer { lock.unlock() }; return danceById[id] }

    // MARK: - Files

    func localCacheURL(for name: String) -> URL { cacheDir.appendingPathComponent(name) }

    /// A usable local copy, if there already is one: bundled first, then the download cache.
    func localURL(for name: String) -> URL? {
        if let bundled = bundleURL(for: name) { return bundled }
        let local = localCacheURL(for: name)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    func bundleURL(for name: String) -> URL? {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let e = ext.isEmpty ? nil : ext
        if let url = Bundle.main.url(forResource: stem, withExtension: e) { return url }
        for dir in ["Res", "Res/builtin", "Res/music"] {
            if let url = Bundle.main.url(forResource: stem, withExtension: e, subdirectory: dir) {
                return url
            }
        }
        return nil
    }

    /// Local copy of `path`, downloading it once if it is not already here.
    func resolve(_ path: AssetPath) async throws -> URL {
        if let local = localURL(for: path.assetName) { return local }
        return try await ensureDownloaded(path)
    }

    func resolveCharacterModel(_ id: String) async throws -> URL {
        guard let path = character(id)?.model else { throw AssetError.notInCatalog(id) }
        return try await resolve(path)
    }

    /// Drop a cached file so the next `resolve` fetches it again. Called when what came down does
    /// not parse: a truncated body or a stored error page used to sit under the asset's name and
    /// fail on every later launch with nothing to clear it.
    func evict(_ path: AssetPath) {
        let local = localCacheURL(for: path.assetName)
        guard FileManager.default.fileExists(atPath: local.path) else { return }
        try? FileManager.default.removeItem(at: local)
        NSLog("[RemoteAssets] evicted %@", path.assetName)
    }

    func ensureDownloaded(_ path: AssetPath) async throws -> URL {
        let key = path.assetName
        if let local = localURL(for: key) { return local }

        let task: Task<URL, Error> = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inFlight[key] { return existing }
            let t = Task<URL, Error> { [weak self] in
                guard let self else { throw AssetError.cancelled }
                defer {
                    self.lock.lock(); self.inFlight[key] = nil; self.lock.unlock()
                    Task { @MainActor in self.progress[key] = nil }
                }
                return try await self.download(path)
            }
            inFlight[key] = t
            return t
        }()
        return try await task.value
    }

    private func download(_ path: AssetPath) async throws -> URL {
        let key = path.assetName
        if let local = localURL(for: key) { return local }
        // Timed and sized. A character model is 17-26MB; on a slow connection this wait is the
        // most likely place to lose somebody who has already chosen what they want to make, and
        // right now it is completely invisible.
        let started = CFAbsoluteTimeGetCurrent()
        guard let base = snapshotBaseUrl(), let url = URL(string: base + path) else {
            throw AssetError.noBaseURL(path)
        }

        await MainActor.run { self.progress[key] = 0 }

        let (tmp, response) = try await downloader.download(url: url, session: session) { [weak self] done, total in
            guard let self, total > 0 else { return }
            let p = min(1, Double(done) / Double(total))
            Task { @MainActor in self.progress[key] = p }
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            Track.log(.assetDownload, ["kind": kind(of: path), "ok": "no",
                                       "status": (response as? HTTPURLResponse)?.statusCode ?? -1,
                                       "ms": Track.ms(since: started)])
            throw AssetError.http((response as? HTTPURLResponse)?.statusCode ?? -1, path)
        }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
        Track.log(.assetDownload, ["kind": kind(of: path), "ok": "yes",
                                   "mb": (Double(bytes) / 1e6 * 10).rounded() / 10,
                                   "ms": Track.ms(since: started)])

        let local = localCacheURL(for: key)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
        return local
    }

    /// character / dance / thumb, from the path the index gave. Kept coarse on purpose: the useful
    /// question is which *class* of asset is slow, and a per-file breakdown is already available
    /// from the catalog itself.
    private func kind(of path: AssetPath) -> String {
        if path.hasPrefix("characters/") { return "character" }
        if path.hasPrefix("dances/") { return "dance" }
        if path.hasPrefix("thumbs/") { return "thumb" }
        return "other"
    }

    private func snapshotBaseUrl() -> String? {
        lock.lock(); defer { lock.unlock() }
        return catalog?.baseUrl
    }

    enum AssetError: LocalizedError {
        case noBaseURL(String), http(Int, String), notInCatalog(String), cancelled
        var errorDescription: String? {
            switch self {
            case .noBaseURL(let f):    return "No index baseUrl to fetch \(f) from"
            case .http(let c, let f):  return "HTTP \(c) for \(f)"
            case .notInCatalog(let f): return "\(f) is not in the index"
            case .cancelled:           return "Cancelled"
            }
        }
    }
}

/// The character and dance that ship inside the app, so a first launch performs with no download.
/// Read from the index rather than written here - see `BuiltInSet`.
enum BuiltInAssets {
    static var characterId: String { RemoteAssets.shared.builtIn?.character ?? "" }
    static var danceId: String { RemoteAssets.shared.builtIn?.dance ?? "" }

    static func isBuiltIn(character id: String) -> Bool { !id.isEmpty && id == characterId }
    static func isBuiltIn(dance id: String) -> Bool { !id.isEmpty && id == danceId }
}

// MARK: - Download with progress

private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private struct State {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let onProgress: (Int64, Int64) -> Void
    }

    private let lock = NSLock()
    private var tasks: [Int: State] = [:]

    func download(url: URL, session: URLSession,
                  onProgress: @escaping (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { c in
            let task = session.downloadTask(with: url)
            lock.lock()
            tasks[task.taskIdentifier] = State(continuation: c, onProgress: onProgress)
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let state = tasks[downloadTask.taskIdentifier]
        lock.unlock()
        state?.onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let response = downloadTask.response ?? URLResponse()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-" + UUID().uuidString)
        lock.lock()
        let state = tasks.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let s = state else { return }
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            s.continuation.resume(returning: (dest, response))
        } catch {
            s.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = tasks.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let s = state, let error = error {
            s.continuation.resume(throwing: error)
        }
    }
}
