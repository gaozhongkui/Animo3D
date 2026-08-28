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
    /// onProgress returns 0…1 download progress (on main thread), used to show progress bar.
    func downloadUSDZ(uid: String, onProgress: ((Double) -> Void)? = nil) async throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("sketchfab_usdz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(uid).usdz")
        if FileManager.default.fileExists(atPath: dest.path) {
            onProgress?(1)
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
        onProgress?(1)
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
    private let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress(min(max(p, 0), 1)) }
    }

    // When using async download(for:delegate:), the file is returned by system API, no need to handle saving here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
