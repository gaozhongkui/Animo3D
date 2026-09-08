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

    // Dedicated for large file downloads: bypasses system proxies (like sing-box), uses timeout, avoids connection hang.
    private lazy var dlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // Built-in API Token (base64, only for simple obfuscation, not encrypted).
    private var apiToken: String {
        let b64 = "MzZmOGNlNDIwNmQ5NDk5OWEyNmI3MzIxZWM2NDBkMDU="
        return String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? ""
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
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("sketchfab_usdz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(uid).usdz")
        if FileManager.default.fileExists(atPath: dest.path) {
            // Already cached: report it complete against its own size, so the caller shows 100%
            // rather than a fraction of an unknown total.
            let n = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            onProgress?(n ?? 0, n ?? 0)
            return dest
        }

        let remote = try await fetchUSDZURL(uid: uid)
        // Use download task with progress (dedicated dlSession bypasses system proxy to avoid connection hang).
        let req = URLRequest(url: remote)
        let delegate = onProgress.map { DownloadProgressDelegate(onProgress: $0) }
        let (tmp, response) = try await dlSession.download(for: req, delegate: delegate)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else { throw SketchfabError.httpError(code) }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        let n = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        onProgress?(n ?? 0, n ?? 0)
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
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64, Int64?) -> Void
    init(onProgress: @escaping (Int64, Int64?) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // -1 is NSURLSessionTransferSizeUnknown: reported as nil rather than swallowed, so the UI
        // can show bytes received instead of a fraction that would be a lie.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        DispatchQueue.main.async { self.onProgress(totalBytesWritten, total) }
    }

    // When using async download(for:delegate:), the file is returned by system API, no need to handle saving here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
