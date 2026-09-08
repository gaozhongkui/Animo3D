//
//  SketchfabClient.swift
//  Animo3D
//
//  Sketchfab Data API Client: Get popular downloadable models.
//  Documentation: https://developers.sketchfab.com/data-api/v3/
//

import Foundation

struct SketchfabImage: Codable {
    let url: String
    let width: Int
    let height: Int
}

struct SketchfabThumbnail: Codable {
    let images: [SketchfabImage]
}

struct SketchfabModel: Codable, Identifiable {
    let uid: String
    let name: String
    let viewerUrl: String
    let embedUrl: String
    let likeCount: Int
    let viewCount: Int
    let thumbnails: SketchfabThumbnail

    var id: String { uid }

    var bestThumbnail: String? {
        // Look for a preview image with width near 720 or the largest available
        let sorted = thumbnails.images.sorted { $0.width > $1.width }
        return sorted.first(where: { $0.width <= 1024 })?.url ?? sorted.last?.url
    }
}

struct SketchfabResponse: Codable {
    let results: [SketchfabModel]
    let next: String?
}

/// Format entries returned by the download API.
private struct SketchfabDownload: Codable {
    struct Entry: Codable { let url: String; let size: Int }
    let usdz: Entry?
    let glb: Entry?
    let gltf: Entry?
}

enum SketchfabError: LocalizedError {
    case notDownloadable
    case noUSDZ
    case rateLimited
    case httpError(Int)
    var errorDescription: String? {
        switch self {
        case .notDownloadable: return L("This model can't be downloaded (the author hasn't enabled it, or the license doesn't allow it)")
        case .noUSDZ:          return L("This model has no AR (USDZ) format available")
        case .rateLimited:     return L("Too many requests — please try again in a few seconds")
        case .httpError(let c): return String(format: L("Request failed (%d)"), c)
        }
    }
}

final class SketchfabClient {
    static let shared = SketchfabClient()
    private let session = URLSession.shared

    /// Large downloads go through this, not `session`: it reports progress, and its own
    /// configuration bypasses system proxies (a sing-box proxy was hanging the connection outright).
    private let downloader = ProgressiveDownloader()

    // Built-in API Token (base64, only for simple obfuscation, not encrypted).
    private var apiToken: String {
        let b64 = "MzZmOGNlNDIwNmQ5NDk5OWEyNmI3MzIxZWM2NDBkMDU="
        return String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? ""
    }

    // MARK: - Where downloaded models live

    /// Downloaded models are kept in Application Support, **not** in Caches.
    ///
    /// Caches is where they used to live, and iOS is entitled to delete anything in it whenever the
    /// device is short of space - without telling the app, and between launches. A model is 16-17MB,
    /// so a handful of them is exactly the kind of thing the system reclaims first. That is the
    /// "I already downloaded this, why is it downloading again" report: the file really was gone.
    ///
    /// Application Support is not purged. It is excluded from backup instead, because these are
    /// re-downloadable copies of someone else's files and have no business in the user's iCloud
    /// backup - which is the one legitimate reason Caches looked like the right place.
    static let modelsDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("community_models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)

        // One-time move of anything the old build left in Caches, so nobody re-downloads a model
        // they already have just because it changed address.
        let old = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sketchfab_usdz", isDirectory: true)
        if let stale = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for file in stale {
                let target = dir.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
            try? fm.removeItem(at: old)
        }
        return dir
    }()

    /// How much disk the downloaded models may take before the oldest are dropped.
    ///
    /// Unbounded before: every model the user opened in AR stayed for good, so an evening of
    /// browsing turned into hundreds of megabytes that only a manual "Clear Cache" tap would
    /// release. Least-recently-used, by modification date, which `cachedModel` touches on a hit.
    private static let modelsBudget: Int64 = 500 * 1024 * 1024

    /// The local copy of a model, if it is on disk. Touching it on the way out is what makes the
    /// eviction below least-recently-*used* rather than oldest-downloaded.
    static func cachedModel(uid: String) -> URL? {
        let url = modelsDirectory.appendingPathComponent("\(uid).usdz")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var values = URLResourceValues()
        values.contentModificationDate = Date()
        var touched = url
        try? touched.setResourceValues(values)
        return url
    }

    /// Drop the least recently used models until the directory is back inside its budget.
    private static func enforceBudget() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: modelsDirectory,
                                                      includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = files.compactMap {
            guard let v = try? $0.resourceValues(forKeys: Set(keys)) else { return nil }
            return ($0, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > modelsBudget else { return }
        entries.sort { $0.date < $1.date }              // oldest first
        for entry in entries where total > modelsBudget {
            try? fm.removeItem(at: entry.url)
            total -= entry.size
            NSLog("[Sketchfab] evicted %@", entry.url.lastPathComponent)
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Get temporary USDZ download URL for the model (download interface requires auth; link expires in ~5 mins, use immediately).
    func fetchUSDZURL(uid: String) async throws -> URL {
        guard let ep = URL(string: "https://api.sketchfab.com/v3/models/\(uid)/download") else {
            throw SketchfabError.httpError(-2)
        }
        var req = URLRequest(url: ep)
        req.setValue("Token \(apiToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if code == 403 || code == 404 { throw SketchfabError.notDownloadable }
        if code == 429 { throw SketchfabError.rateLimited }
        guard (200...299).contains(code) else { throw SketchfabError.httpError(code) }
        let dl = try JSONDecoder().decode(SketchfabDownload.self, from: data)
        guard let usdz = dl.usdz, let url = URL(string: usdz.url) else { throw SketchfabError.noUSDZ }
        return url
    }

    /// Download USDZ to cache directory (named by uid, reuses if already exists). Returns local file URL.
    /// Reports download progress on the main thread as `(received, total)` bytes.
    ///
    /// `total` is nil when the server does not say - Sketchfab hands out an S3 redirect, and without
    /// a Content-Length `totalBytesExpectedToWrite` is -1. The old callback reported a single 0…1
    /// fraction and simply returned early in that case, so the ring sat at 0% for the whole download
    /// and then jumped to 100%. The caller needs to know the difference to show something honest.
    func downloadUSDZ(uid: String, onProgress: ((Int64, Int64?) -> Void)? = nil) async throws -> URL {
        let dest = Self.modelsDirectory.appendingPathComponent("\(uid).usdz")
        if let cached = Self.cachedModel(uid: uid) {
            // Already on disk: report it complete against its own size, so the caller shows 100%
            // rather than a fraction of an unknown total.
            let n = Self.fileSize(cached)
            onProgress?(n, n)
            return cached
        }

        let remote = try await fetchUSDZURL(uid: uid)
        let response = try await downloader.download(URLRequest(url: remote), to: dest,
                                                     onProgress: onProgress)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else { throw SketchfabError.httpError(code) }
        // A last call at the real size: the final progress callback can land a chunk short of the
        // total, which leaves the ring parked at 99%.
        let n = Self.fileSize(dest)
        Self.enforceBudget()
        onProgress?(n, n)
        return dest
    }

    func fetchModels(query: String? = nil, category: String? = nil, nextUrl: String? = nil) async throws -> SketchfabResponse {
        // Use nextUrl directly if available
        if let next = nextUrl, let url = URL(string: next) {
            return try await performFetch(url: url)
        }

        // Construct initial URL
        var components = URLComponents(string: "https://api.sketchfab.com/v3/models")!
        var queryItems = [
            URLQueryItem(name: "type", value: "models"),
            URLQueryItem(name: "downloadable", value: "true"),
            URLQueryItem(name: "sort_by", value: "-likeCount")
        ]

        // Handle category filtering (using categories parameter supported by official API)
        let categoryMap: [String: String] = [
            "Trending": "characters-creatures", // default
            "Characters": "characters-creatures",
            "Animals": "animals-pets",
            "Buildings": "architecture",
            "Vehicles": "cars-vehicles",
            "Fantasy": "fantasy"
        ]

        if let cat = category, let slug = categoryMap[cat] {
            queryItems.append(URLQueryItem(name: "categories", value: slug))
        }

        // Handle keyword search
        if let q = query, !q.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw NSError(domain: "SketchfabClient", code: -2, userInfo: [NSLocalizedDescriptionKey: L("Invalid URL")])
        }

        return try await performFetch(url: url)
    }

    private func performFetch(url: URL) async throws -> SketchfabResponse {
        var req = URLRequest(url: url)
        // Even for public model searches, including the Token usually results in a more stable response
        req.setValue("Token \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SketchfabClient", code: -1, userInfo: [NSLocalizedDescriptionKey: L("Unexpected network response")])
        }

        if httpResponse.statusCode == 429 {
            throw SketchfabError.rateLimited
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SketchfabError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(SketchfabResponse.self, from: data)
    }
}

/// Download progress delegate: callbacks 0…1 progress to main thread (for progress bar).
/// A download that actually reports progress.
///
/// The obvious way to write this is `URLSession.download(for:delegate:)`, which takes a delegate
/// and is what this used to do - and it is why the community model's progress ring sat at zero all
/// the way through a download that was working fine. That call accepts the delegate and then never
/// sends it `didWriteData`. Measured against a 20MB file: **0** callbacks through the task
/// delegate, **106** through a session delegate on a plain `downloadTask`.
///
/// So the session owns the delegate, and a continuation turns the callbacks back into one `await`.
/// One downloader is shared by every download; jobs are keyed by task identifier, since a session
/// delegate is told about every task on the session rather than about one.
private final class ProgressiveDownloader: NSObject, URLSessionDownloadDelegate {
    private struct Job {
        let dest: URL
        let onProgress: ((Int64, Int64?) -> Void)?
        let cont: CheckedContinuation<URLResponse, Error>
    }

    private var jobs: [Int: Job] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]      // ignore a system proxy; sing-box hung the connection
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Downloads to `dest`, replacing whatever is there, and returns the response so the caller can
    /// judge the status code.
    func download(_ req: URLRequest, to dest: URL,
                  onProgress: ((Int64, Int64?) -> Void)?) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { cont in
            let task = session.downloadTask(with: req)
            lock.lock()
            jobs[task.taskIdentifier] = Job(dest: dest, onProgress: onProgress, cont: cont)
            lock.unlock()
            task.resume()
        }
    }

    /// Claims a job. Whichever callback gets it resumes the continuation, and the other then finds
    /// nothing - which is what keeps a completion and an error from resuming the same continuation
    /// twice, a trap rather than a warning.
    private func claim(_ id: Int) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs.removeValue(forKey: id)
    }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let onProgress = jobs[task.taskIdentifier]?.onProgress
        lock.unlock()
        guard let onProgress else { return }
        // -1 is NSURLSessionTransferSizeUnknown: reported as nil rather than swallowed, so the UI
        // can show bytes received instead of a fraction that would be a lie.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        DispatchQueue.main.async { onProgress(totalBytesWritten, total) }
    }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let job = claim(task.taskIdentifier) else { return }
        let response = task.response ?? URLResponse()
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        // The system deletes `location` the moment this returns, so the file is moved here or not
        // at all. Only for a 2xx: this callback fires for a 404 as well, and its body is the error
        // page, which would otherwise be cached under the model's own name and loaded as a model.
        if (200...299).contains(code) {
            do {
                try? FileManager.default.removeItem(at: job.dest)
                try FileManager.default.moveItem(at: location, to: job.dest)
            } catch {
                job.cont.resume(throwing: error)
                return
            }
        }
        job.cont.resume(returning: response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let job = claim(task.taskIdentifier) else { return }
        job.cont.resume(throwing: error)
    }
}
