//
//  RemoteAssets.swift
//  Animo3D
//
//  Remote asset catalog + download cache.
//
//  The app ships without characters, dances or music: those live in a GitHub Release and are
//  pulled on demand into Caches/RemoteAssets. This file owns two things:
//    - the catalog (what exists, which file each entry maps to, how big it is, its sha256)
//    - the downloader (fetch one file, once, verified, with progress)
//
//  Design notes:
//  - `baseUrl` starts from a compiled-in constant and is only *refreshed* by index.json. Downloads
//    therefore never wait on a network round trip to start, and a failed index fetch degrades to
//    "assets still work", not "nothing works".
//  - The catalog is seeded from `seed_catalog.json` in the bundle, then overridden by the last
//    successful network catalog cached on disk. A cold, offline launch still shows a full list.
//  - Every download is deduplicated by remote filename and verified against the catalog's sha256:
//    a truncated file used to land in the cache permanently, clearable only by deleting the app.
//

import Foundation
import Combine
import CryptoKit

// MARK: - Catalog models

/// One downloadable file as described by the catalog.
struct AssetRef: Decodable, Hashable {
    let file: String
    let bytes: Int?
    let sha256: String?

    init(file: String, bytes: Int? = nil, sha256: String? = nil) {
        self.file = file
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// A character, dance or music entry. All three share one shape; the optional fields say which is which.
///
/// Everything the catalog knows is decoded here on purpose. Keeping only `key`/`name` forced the
/// client to *guess* filenames (`key.contains("vroid") ? .usdz : .scn`, trying `.mp3` then `.m4a`,
/// hand-assembling `vrm_`/`mocap_` prefixes). The server already states all of it.
struct CatalogItem: Identifiable, Decodable {
    let key: String
    let name: String

    // characters and music: the asset itself
    let file: String?
    let bytes: Int?
    let sha256: String?
    let rig: String?                     // characters only: "vrm" | "mixamo"

    // dances: one clip per rig
    let clips: [String: AssetRef]?

    // optional pre-rendered card image (emitted by tools/make_catalog.py)
    let thumb: AssetRef?
    // dances: a single-frame extract of the mixamo clip, purely so a card can strike the pose.
    // ~2KB instead of the ~750KB full clip - a 44-card grid costs 88KB rather than 21MB.
    let pose: AssetRef?

    var id: String { key }
    var isVRM: Bool { rig == "vrm" }

    /// The file to download for this entry (characters and music).
    var asset: AssetRef? {
        guard let file else { return nil }
        return AssetRef(file: file, bytes: bytes, sha256: sha256)
    }

    /// The clip for a rig. Mixamo clips are world-space joint positions, so PoseRetargeter can drive
    /// any skeleton with them - they are the correct fallback when a rig-specific clip is missing.
    func clip(rig: String) -> AssetRef? { clips?[rig] ?? clips?["mixamo"] }
}

struct RemoteIndex: Decodable {
    let catalog: String
    let baseUrl: String
}

struct RemoteCatalog: Decodable {
    let version: String?
    let characters: [CatalogItem]
    let dances: [CatalogItem]
    let music: [CatalogItem]
}

// MARK: - RemoteAssets

final class RemoteAssets: ObservableObject {
    static let shared = RemoteAssets()

    /// Where the index lives. The index only *moves* the asset host; it is not required to use it.
    private let indexURL = URL(string: "https://raw.githubusercontent.com/gaozhongkui/Animo3D/main/dist/index.json")!

    /// Compiled-in asset host, used until index.json says otherwise (and whenever it cannot be reached).
    private static let fallbackBaseUrl = "https://github.com/gaozhongkui/Animo3D/releases/download/assets-v1/"

    @Published private(set) var characters: [CatalogItem] = []
    @Published private(set) var dances: [CatalogItem] = []
    @Published private(set) var music: [CatalogItem] = []
    /// Catalog origin, for diagnostics and for deciding whether to show a "refreshing" hint.
    @Published private(set) var catalogSource: Source = .none
    /// remote filename -> 0...1 while a download is in flight.
    @Published private(set) var progress: [String: Double] = [:]

    enum Source: String { case none, seed, cache, network }

    private let lock = NSLock()
    private var _baseUrl = RemoteAssets.fallbackBaseUrl
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var charByKey: [String: CatalogItem] = [:]
    private var danceByKey: [String: CatalogItem] = [:]
    private var musicByKey: [String: CatalogItem] = [:]

    private var baseUrl: String {
        get { lock.lock(); defer { lock.unlock() }; return _baseUrl }
        set { lock.lock(); _baseUrl = newValue; lock.unlock() }
    }

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 600      // a 60MB model on a bad link still needs to finish
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }()

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteAssets")
    }
    private var catalogCacheURL: URL { cacheDir.appendingPathComponent("_catalog.json") }
    private var baseUrlCacheURL: URL { cacheDir.appendingPathComponent("_baseurl.txt") }

    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Publish something usable before any network call: cached catalog first, bundled seed otherwise.
        if let cached = try? Data(contentsOf: catalogCacheURL),
           let cat = try? JSONDecoder().decode(RemoteCatalog.self, from: cached) {
            apply(cat, source: .cache)
        } else if let seedURL = Bundle.main.url(forResource: "seed_catalog", withExtension: "json"),
                  let data = try? Data(contentsOf: seedURL),
                  let cat = try? JSONDecoder().decode(RemoteCatalog.self, from: data) {
            apply(cat, source: .seed)
        }
        if let saved = try? String(contentsOf: baseUrlCacheURL, encoding: .utf8) {
            let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { baseUrl = trimmed }
        }
        Task { await refresh() }
    }

    // MARK: - Catalog

    /// Fetch index + catalog. Failure is non-fatal: whatever was seeded or cached stays in place.
    func refresh() async {
        do {
            let (data, _) = try await session.data(from: indexURL)
            let index = try JSONDecoder().decode(RemoteIndex.self, from: data)
            baseUrl = index.baseUrl
            try? index.baseUrl.write(to: baseUrlCacheURL, atomically: true, encoding: .utf8)

            let catalogURL = indexURL.deletingLastPathComponent().appendingPathComponent(index.catalog)
            let (catData, _) = try await session.data(from: catalogURL)
            let cat = try JSONDecoder().decode(RemoteCatalog.self, from: catData)
            try? catData.write(to: catalogCacheURL, options: .atomic)
            apply(cat, source: .network)
        } catch {
            NSLog("[RemoteAssets] catalog refresh failed (still using %@): %@",
                  catalogSource.rawValue, error.localizedDescription)
        }
    }

    /// Lookup tables live behind the lock: they are read from background threads (thumbnail render
    /// queue, detached parse tasks) while the published arrays are only touched on the main thread.
    private func apply(_ cat: RemoteCatalog, source: Source) {
        lock.lock()
        charByKey = Dictionary(cat.characters.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        danceByKey = Dictionary(cat.dances.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        musicByKey = Dictionary(cat.music.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()

        let publish = { [weak self] in
            guard let self else { return }
            self.characters = cat.characters
            self.dances = cat.dances
            self.music = cat.music
            self.catalogSource = source
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }

        NSLog("[RemoteAssets] catalog(%@) characters=%d dances=%d music=%d",
              source.rawValue, cat.characters.count, cat.dances.count, cat.music.count)
    }

    func character(_ key: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return charByKey[key] }
    func dance(_ key: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return danceByKey[key] }
    func musicItem(_ key: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return musicByKey[key] }

    /// The clip a given character needs for a given dance, resolved through the catalog.
    func clip(dance danceKey: String, forCharacter characterKey: String) -> AssetRef? {
        guard let d = dance(danceKey) else { return nil }
        let rig = character(characterKey)?.rig ?? "mixamo"
        return d.clip(rig: rig)
    }

    // MARK: - Files

    func localCacheURL(for remoteFile: String) -> URL {
        cacheDir.appendingPathComponent(remoteFile)
    }

    /// A ready-to-use local URL, or nil if the file still has to be fetched.
    func localURL(for remoteFile: String) -> URL? {
        // ML models stay in the bundle: they are needed before any network is available.
        if remoteFile.contains("pose_landmarker") {
            return Bundle.main.url(forResource: remoteFile, withExtension: nil)
        }
        let local = localCacheURL(for: remoteFile)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// The bundled copy of an asset, if it ships inside the app (Res/builtin, or a dev drop-in).
    func bundleURL(for file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext.isEmpty ? nil : ext)
    }

    /// Resolve an asset to a local URL: a bundled copy wins, otherwise download and verify.
    func resolve(_ ref: AssetRef) async throws -> URL {
        try await resolve(file: ref.file, sha256: ref.sha256, bytes: ref.bytes)
    }

    func resolve(file: String, sha256: String? = nil, bytes: Int? = nil) async throws -> URL {
        if let bundled = bundleURL(for: file) { return bundled }
        return try await ensureDownloaded(remoteFile: file, sha256: sha256, expectedBytes: bytes)
    }

    /// Resolve a character's model, taking size and checksum from the catalog when it knows them.
    func resolveCharacterModel(_ key: String) async throws -> URL {
        if let ref = character(key)?.asset { return try await resolve(ref) }
        return try await resolve(file: characterModelFile(key))
    }

    func ensureDownloaded(_ ref: AssetRef) async throws -> URL {
        try await ensureDownloaded(remoteFile: ref.file, sha256: ref.sha256, expectedBytes: ref.bytes)
    }

    /// Download once and cache. Concurrent callers for the same file share a single transfer.
    func ensureDownloaded(remoteFile: String, sha256: String? = nil, expectedBytes: Int? = nil) async throws -> URL {
        if let local = localURL(for: remoteFile) { return local }

        let task: Task<URL, Error> = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inFlight[remoteFile] { return existing }
            let t = Task<URL, Error> { [weak self] in
                guard let self else { throw AssetError.cancelled }
                defer {
                    self.lock.lock(); self.inFlight[remoteFile] = nil; self.lock.unlock()
                    Task { @MainActor in self.progress[remoteFile] = nil }
                }
                return try await self.download(remoteFile, sha256: sha256, expectedBytes: expectedBytes)
            }
            inFlight[remoteFile] = t
            return t
        }()
        return try await task.value
    }

    private func download(_ remoteFile: String, sha256 expected: String?, expectedBytes: Int?) async throws -> URL {
        // Another task may have finished this file while we were queued.
        if let local = localURL(for: remoteFile) { return local }
        guard let url = URL(string: baseUrl + remoteFile) else { throw AssetError.badURL(remoteFile) }

        await MainActor.run { self.progress[remoteFile] = 0 }
        let (tmp, response) = try await Downloader.download(session: session, url: url, onProgress: { [weak self] done, total in
            guard let self, total > 0 else { return }
            let p = min(1, Double(done) / Double(total))
            Task { @MainActor in self.progress[remoteFile] = p }
        }, fallbackTotal: { expectedBytes.map(Int64.init) ?? -1 })

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw AssetError.http((response as? HTTPURLResponse)?.statusCode ?? -1, remoteFile)
        }
        if let expected {
            let actual = try Self.sha256Hex(of: tmp)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: tmp)
                NSLog("[RemoteAssets] checksum mismatch %@ want=%@ got=%@", remoteFile, expected, actual)
                throw AssetError.checksum(remoteFile)
            }
        }

        let local = localCacheURL(for: remoteFile)
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
        return local
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum AssetError: LocalizedError {
        case badURL(String), http(Int, String), checksum(String), cancelled

        var errorDescription: String? {
            switch self {
            case .badURL(let f):      return "Bad asset URL for \(f)"
            case .http(let c, let f): return "HTTP \(c) for \(f)"
            case .checksum(let f):    return "Checksum mismatch for \(f)"
            case .cancelled:          return "Cancelled"
            }
        }
    }
}

/// Assets that ship inside the app so it works with no network at all.
///
/// Without these, a cold launch on a bad connection leaves every card on a spinner and nothing can
/// be played. One character and one dance are ~5MB and make the whole flow usable offline; they
/// resolve from the bundle through `RemoteAssets.resolve`, exactly like a cached download would.
enum BuiltInAssets {
    static let characterKey = "vroid_4"
    static let danceKey = "Hip_Hop_Dancing"

    static func isBuiltIn(character key: String) -> Bool { key == characterKey }
    static func isBuiltIn(dance key: String) -> Bool { key == danceKey }
}

// MARK: - Download with progress

/// `URLSession.download(from:)` reports no progress, and `AsyncBytes` iterates one byte at a time
/// (unusably slow for a 60MB model). A delegate is the only route that reports bytes as they land.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    typealias ProgressHandler = (Int64, Int64) -> Void

    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private let onProgress: ProgressHandler
    private let fallbackTotal: () -> Int64
    private var kept: Downloader?          // keeps self alive for the lifetime of the transfer

    private init(onProgress: @escaping ProgressHandler, fallbackTotal: @escaping () -> Int64) {
        self.onProgress = onProgress
        self.fallbackTotal = fallbackTotal
    }

    /// Downloads to a temporary file the caller owns: URLSession deletes the delegate's file as soon
    /// as the callback returns, so it is moved aside first.
    static func download(session: URLSession,
                         url: URL,
                         onProgress: @escaping ProgressHandler,
                         fallbackTotal: @escaping () -> Int64) async throws -> (URL, URLResponse) {
        let d = Downloader(onProgress: onProgress, fallbackTotal: fallbackTotal)
        d.kept = d
        let delegateSession = URLSession(configuration: session.configuration, delegate: d, delegateQueue: nil)
        defer { delegateSession.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            delegateSession.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackTotal()
        onProgress(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let response = downloadTask.response ?? URLResponse()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-" + UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success((dest, response)))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        guard let c = continuation else { return }
        continuation = nil
        kept = nil
        c.resume(with: result)
    }
}
