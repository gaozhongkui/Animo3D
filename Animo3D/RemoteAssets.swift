//
//  RemoteAssets.swift
//  Animo3D
//
//  Remote asset catalog + download cache (Supabase Edition).
//

import Foundation
import Combine

// MARK: - Catalog models

/// One downloadable file as described by the catalog.
struct AssetRef: Decodable, Hashable {
    let url: String

    var file: String { (url as NSString).lastPathComponent }

    init(url: String) {
        self.url = url
    }
}

/// A character or dance entry. Simplified flat structure.
struct CatalogItem: Identifiable, Decodable {
    let id: String
    let name: String

    // Primary asset (model for characters, mixamo clip for dances)
    let url: String?

    // Characters only
    let rig: String?                     // "vrm" | "mixamo"
    let thumb_url: String?

    // Dances only
    let vrm_url: String?
    let pose_url: String?
    let duration: Double?

    var isVRM: Bool { rig == "vrm" }

    /// The primary asset reference.
    var asset: AssetRef? {
        guard let url else { return nil }
        return AssetRef(url: url)
    }

    /// The pre-rendered thumbnail reference.
    var thumb: AssetRef? {
        guard let thumb_url else { return nil }
        return AssetRef(url: thumb_url)
    }

    /// The single-frame pose reference.
    var pose: AssetRef? {
        guard let pose_url else { return nil }
        return AssetRef(url: pose_url)
    }

    /// The clip for a rig.
    func clip(rig: String) -> AssetRef? {
        if rig == "vrm", let vurl = vrm_url {
            return AssetRef(url: vurl)
        }
        return asset
    }
}

struct RemoteCatalog: Decodable {
    let version: String?
    let characters: [CatalogItem]
    let dances: [CatalogItem]
    let music: [CatalogItem]?
}

// MARK: - RemoteAssets

final class RemoteAssets: ObservableObject {
    static let shared = RemoteAssets()

    /// Where the unified index lives.
    private let indexURL = URL(string: "https://dekbcnbakegjgbjxflxe.supabase.co/storage/v1/object/sign/models/index.json?token=eyJraWQiOiIxZTQ5YjE5Ni01ZjlhLTRiNmUtYjdlYS0yODAzODY2ZTEyYzMiLCJhbGciOiJIUzUxMiJ9.eyJ1cmwiOiJtb2RlbHMvaW5kZXguanNvbiIsInNjb3BlIjoiZG93bmxvYWQiLCJpYXQiOjE3ODg1MTk3MTgsImV4cCI6MTgyMDA1NTcxOH0.8kTqWITC1kygqpDVdG8Rik59ql8Rcfek8GIfMsnZ2ITY6O-yRRitXQcsTwU8ln1IpKh7AQiw5rrVZflTGsMp8g")!

    @Published private(set) var characters: [CatalogItem] = []
    @Published private(set) var dances: [CatalogItem] = []
    @Published private(set) var music: [CatalogItem] = []
    @Published private(set) var catalogSource: Source = .none
    @Published private(set) var progress: [String: Double] = [:]

    enum Source: String { case none, seed, cache, network }

    var activeDownloadProgress: Double? { progress.values.min() }

    private let lock = NSLock()
    private var inFlight: [String: Task<URL, Error>] = [:]
    private var charById: [String: CatalogItem] = [:]
    private var danceById: [String: CatalogItem] = [:]

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
    private var catalogCacheURL: URL { cacheDir.appendingPathComponent("_catalog.json") }

    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let cached = try? Data(contentsOf: catalogCacheURL),
           let cat = try? JSONDecoder().decode(RemoteCatalog.self, from: cached) {
            apply(cat, source: .cache)
        }
        Task { await refresh() }
    }

    // MARK: - Catalog

    func refresh() async {
        do {
            let (data, _) = try await session.data(from: indexURL)
            let cat = try JSONDecoder().decode(RemoteCatalog.self, from: data)
            try? data.write(to: catalogCacheURL, options: .atomic)
            apply(cat, source: .network)
        } catch {
            NSLog("[RemoteAssets] catalog refresh failed (still using %@): %@",
                  catalogSource.rawValue, error.localizedDescription)
        }
    }

    private func apply(_ cat: RemoteCatalog, source: Source) {
        lock.lock()
        charById = Dictionary(cat.characters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        danceById = Dictionary(cat.dances.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let musicItems = cat.music ?? []
        musicById = Dictionary(musicItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()

        let publish = { [weak self] in
            guard let self else { return }
            self.characters = cat.characters
            self.dances = cat.dances
            self.music = musicItems
            self.catalogSource = source
        }
        if Thread.isMainThread { publish() } else { DispatchQueue.main.async(execute: publish) }
    }

    func character(_ id: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return charById[id] }
    func dance(_ id: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return danceById[id] }
    func musicItem(_ id: String) -> CatalogItem? { lock.lock(); defer { lock.unlock() }; return musicById[id] }

    func clip(dance danceId: String, forCharacter characterId: String) -> AssetRef? {
        guard let d = dance(danceId) else { return nil }
        let rig = character(characterId)?.rig ?? "mixamo"
        return d.clip(rig: rig)
    }

    // MARK: - Files

    func localCacheURL(for remoteFile: String) -> URL {
        cacheDir.appendingPathComponent(remoteFile)
    }

    func localURL(for remoteFile: String) -> URL? {
        if let bundled = bundleURL(for: remoteFile) { return bundled }
        let local = localCacheURL(for: remoteFile)
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    func bundleURL(for file: String) -> URL? {
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        let e = ext.isEmpty ? nil : ext
        if let url = Bundle.main.url(forResource: name, withExtension: e) { return url }
        for dir in ["Res", "Res/builtin", "Res/thumbs"] {
            if let url = Bundle.main.url(forResource: name, withExtension: e, subdirectory: dir) {
                return url
            }
        }
        return nil
    }

    func resolve(_ ref: AssetRef) async throws -> URL {
        try await resolve(url: ref.url)
    }

    func resolve(url: String) async throws -> URL {
        let file = (url as NSString).lastPathComponent
        if let bundled = bundleURL(for: file) { return bundled }
        return try await ensureDownloaded(remoteUrl: url)
    }

    func resolveCharacterModel(_ id: String) async throws -> URL {
        if let ref = character(id)?.asset { return try await resolve(ref) }
        return try await resolve(url: "char_\(id).scn") // Basic fallback
    }

    func ensureDownloaded(_ ref: AssetRef) async throws -> URL {
        try await ensureDownloaded(remoteUrl: ref.url)
    }

    func ensureDownloaded(remoteUrl: String) async throws -> URL {
        let file = (remoteUrl as NSString).lastPathComponent
        if let local = localURL(for: file) { return local }

        let task: Task<URL, Error> = {
            lock.lock()
            defer { lock.unlock() }
            if let existing = inFlight[file] { return existing }
            let t = Task<URL, Error> { [weak self] in
                guard let self else { throw AssetError.cancelled }
                defer {
                    self.lock.lock(); self.inFlight[file] = nil; self.lock.unlock()
                    Task { @MainActor in self.progress[file] = nil }
                }
                return try await self.download(remoteUrl)
            }
            inFlight[file] = t
            return t
        }()
        return try await task.value
    }

    private func download(_ remoteUrl: String) async throws -> URL {
        let remoteFile = (remoteUrl as NSString).lastPathComponent
        if let local = localURL(for: remoteFile) { return local }
        guard let url = URL(string: remoteUrl) else { throw AssetError.badURL(remoteUrl) }

        await MainActor.run { self.progress[remoteFile] = 0 }

        let (tmp, response) = try await downloader.download(url: url, session: session, onProgress: { [weak self] done, total in
            guard let self, total > 0 else { return }
            let p = min(1, Double(done) / Double(total))
            Task { @MainActor in self.progress[remoteFile] = p }
        }, fallbackTotal: { -1 })

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw AssetError.http((response as? HTTPURLResponse)?.statusCode ?? -1, remoteUrl)
        }

        let local = localCacheURL(for: remoteFile)
        try? FileManager.default.createDirectory(at: local.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: local)
        try FileManager.default.moveItem(at: tmp, to: local)
        return local
    }

    enum AssetError: LocalizedError {
        case badURL(String), http(Int, String), cancelled
        var errorDescription: String? {
            switch self {
            case .badURL(let f): return "Bad asset URL: \(f)"
            case .http(let c, let f): return "HTTP \(c) for \(f)"
            case .cancelled: return "Cancelled"
            }
        }
    }
}

/// Assets that ship inside the app.
enum BuiltInAssets {
    static let characterId = "vroid_4"
    static let danceId = "Arms_Hip_Hop_Dance"

    static func isBuiltIn(character id: String) -> Bool { id == characterId }
    static func isBuiltIn(dance id: String) -> Bool { id == danceId }
}

// MARK: - Download with progress

private final class Downloader: NSObject, URLSessionDownloadDelegate {
    private struct State {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
        let onProgress: (Int64, Int64) -> Void
        let fallbackTotal: () -> Int64
    }

    private let lock = NSLock()
    private var tasks: [Int: State] = [:]

    func download(url: URL, session: URLSession,
                  onProgress: @escaping (Int64, Int64) -> Void,
                  fallbackTotal: @escaping () -> Int64) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { c in
            let task = session.downloadTask(with: url)
            lock.lock()
            tasks[task.taskIdentifier] = State(continuation: c, onProgress: onProgress, fallbackTotal: fallbackTotal)
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
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (state?.fallbackTotal() ?? -1)
        state?.onProgress(totalBytesWritten, total)
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
