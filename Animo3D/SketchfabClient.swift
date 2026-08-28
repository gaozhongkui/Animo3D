//
//  SketchfabClient.swift
//  Animo3D
//
//  Sketchfab Data API 客户端：获取热门可下载模型。
//  文档：https://developers.sketchfab.com/data-api/v3/
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
        // 寻找宽度接近 720 或最大的预览图
        let sorted = thumbnails.images.sorted { $0.width > $1.width }
        return sorted.first(where: { $0.width <= 1024 })?.url ?? sorted.last?.url
    }
}

struct SketchfabResponse: Codable {
    let results: [SketchfabModel]
    let next: String?
}

/// 下载接口返回的各格式条目。
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
        case .notDownloadable: return "该模型不可下载（作者未开放或授权不允许）"
        case .noUSDZ:          return "该模型没有可用的 AR(USDZ)格式"
        case .rateLimited:     return "请求过于频繁，请稍等几秒再试"
        case .httpError(let c): return "请求失败（\(c)）"
        }
    }
}

final class SketchfabClient {
    static let shared = SketchfabClient()
    private let session = URLSession.shared

    // 专用于大文件下载：绕过系统代理（sing-box 等）直连，带超时，避免连接卡住。
    private lazy var dlSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // 内置 API Token（base64，仅做简单遮挡，非加密）。
    private var apiToken: String {
        let b64 = "MzZmOGNlNDIwNmQ5NDk5OWEyNmI3MzIxZWM2NDBkMDU="
        return String(data: Data(base64Encoded: b64) ?? Data(), encoding: .utf8) ?? ""
    }

    /// 取模型的 USDZ 临时下载地址（下载接口需鉴权；链接约 5 分钟后过期，需即取即用）。
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

    /// 下载 USDZ 到缓存目录（按 uid 命名，已存在则直接复用）。返回本地文件 URL。
    /// onProgress 回调 0…1 的下载进度（主线程），用于展示进度条。
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
        // 用带进度的下载任务（专用 dlSession 绕过系统代理，避免连接卡住）。
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
        // 如果有 nextUrl，直接使用它
        if let next = nextUrl, let url = URL(string: next) {
            return try await performFetch(url: url)
        }

        // 构造初始 URL
        var components = URLComponents(string: "https://api.sketchfab.com/v3/models")!
        var queryItems = [
            URLQueryItem(name: "type", value: "models"),
            URLQueryItem(name: "downloadable", value: "true"),
            URLQueryItem(name: "sort_by", value: "-likeCount")
        ]

        // 处理分类过滤（使用 API 官方支持的 categories 参数）
        let categoryMap: [String: String] = [
            "人物": "characters-creatures", // 对应 Characters & Creatures
            "动物": "animals-pets",
            "建筑": "architecture",
            "车辆": "cars-vehicles",
            "幻想": "fantasy"
        ]

        if let cat = category, let slug = categoryMap[cat] {
            queryItems.append(URLQueryItem(name: "categories", value: slug))
        }

        // 处理关键词搜索
        if let q = query, !q.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: q))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw NSError(domain: "SketchfabClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效 URL"])
        }

        return try await performFetch(url: url)
    }

    private func performFetch(url: URL) async throws -> SketchfabResponse {
        var req = URLRequest(url: url)
        // 即使是公开模型搜索，带上 Token 通常能获得更稳定的响应
        req.setValue("Token \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SketchfabClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "网络响应异常"])
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

/// 下载进度代理：把 0…1 进度回调到主线程（用于进度条）。
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

    // 使用 async download(for:delegate:) 时文件由系统 API 返回，这里无需处理落地。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
