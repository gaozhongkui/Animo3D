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

final class SketchfabClient {
    static let shared = SketchfabClient()
    private let session = URLSession.shared

    func fetchModels(query: String? = nil, nextUrl: String? = nil) async throws -> SketchfabResponse {
        var urlString = nextUrl ?? "https://api.sketchfab.com/v3/models?type=models&downloadable=true&sort_by=-likeCount"

        if nextUrl == nil, let query = query, !query.isEmpty {
            urlString += "&q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }

        guard let url = URL(string: urlString) else {
            throw NSError(domain: "SketchfabClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "无效 URL"])
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "SketchfabClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "请求失败"])
        }

        let decoder = JSONDecoder()
        // Sketchfab API 使用 camelCase，不需要转换
        return try decoder.decode(SketchfabResponse.self, from: data)
    }
}
