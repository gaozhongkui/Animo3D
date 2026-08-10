//
//  TripoClient.swift
//  Animo3D
//
//  Tripo3D OpenAPI 客户端：上传图片 → 创建 image_to_model 任务 → 轮询 → 拿到模型下载地址。
//  文档：https://docs.tripo3d.ai  （基址 https://api.tripo3d.ai/v2/openapi，Bearer 鉴权）
//
//  注意：字段名依据官方文档整理，拿到你的 API Key 后需实际联调校正。
//

import Foundation

enum TripoError: LocalizedError {
    case http(Int, String)
    case decode(String)
    case taskFailed(String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .decode(let m): return "解析失败: \(m)"
        case .taskFailed(let m): return "任务失败: \(m)"
        }
    }
}

struct TripoResult {
    let status: String        // queued / running / success / failed ...
    let progress: Int
    let modelURL: URL?        // 生成的模型下载地址（成功时）
}

final class TripoClient {
    private let apiKey: String
    private let base = URL(string: "https://api.tripo3d.ai/v2/openapi")!
    private let session = URLSession(configuration: .default)

    init(apiKey: String) { self.apiKey = apiKey }

    private func request(_ path: String, method: String) -> URLRequest {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return r
    }

    /// 上传图片，返回 file_token（后续任务用它引用图片）。
    func uploadImage(data: Data, fileExt: String) async throws -> String {
        var r = request("upload", method: "POST")
        let boundary = "Boundary-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"image.\(fileExt)\"\r\n")
        append("Content-Type: image/\(fileExt)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")
        r.httpBody = body

        let json = try await send(r)
        guard let d = json["data"] as? [String: Any],
              let token = (d["image_token"] as? String) ?? (d["file_token"] as? String) else {
            throw TripoError.decode("上传响应缺少 image_token")
        }
        return token
    }

    /// 创建 image_to_model 任务，返回 task_id。
    func createImageToModelTask(fileToken: String, fileExt: String) async throws -> String {
        var r = request("task", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "type": "image_to_model",
            "file": ["type": fileExt, "file_token": fileToken]
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(r)
        guard let d = json["data"] as? [String: Any],
              let taskId = d["task_id"] as? String else {
            throw TripoError.decode("创建任务响应缺少 task_id")
        }
        return taskId
    }

    /// 对已生成的模型做自动绑骨（Auto-Rig）。spec=mixamo 让骨骼名与 Mixamo 兼容，
    /// 这样可直接复用现有的 Mixamo 重定向映射。返回新的 task_id。
    func createRigTask(modelTaskId: String,
                       spec: String = "mixamo",
                       outFormat: String = "glb") async throws -> String {
        var r = request("task", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "type": "animate_rig",
            "original_model_task_id": modelTaskId,
            "out_format": outFormat,
            "rig_type": "biped",
            "spec": spec
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let json = try await send(r)
        guard let d = json["data"] as? [String: Any],
              let taskId = d["task_id"] as? String else {
            throw TripoError.decode("绑骨任务响应缺少 task_id")
        }
        return taskId
    }

    /// 查询任务状态。
    func getTask(_ taskId: String) async throws -> TripoResult {
        let r = request("task/\(taskId)", method: "GET")
        let json = try await send(r)
        guard let d = json["data"] as? [String: Any] else {
            throw TripoError.decode("任务响应缺少 data")
        }
        let status = (d["status"] as? String) ?? "unknown"
        let progress = (d["progress"] as? Int) ?? 0
        var modelURL: URL?
        if let output = d["output"] as? [String: Any] {
            let urlStr = (output["pbr_model"] as? String)
                ?? (output["model"] as? String)
                ?? (output["base_model"] as? String)
            if let s = urlStr { modelURL = URL(string: s) }
        }
        return TripoResult(status: status, progress: progress, modelURL: modelURL)
    }

    /// 轮询直到成功/失败。progress 回调用于更新 UI。
    func waitForCompletion(taskId: String,
                           onProgress: @escaping (TripoResult) -> Void) async throws -> URL {
        while true {
            let res = try await getTask(taskId)
            await MainActor.run { onProgress(res) }
            switch res.status {
            case "success":
                if let url = res.modelURL { return url }
                throw TripoError.taskFailed("成功但无模型地址")
            case "failed", "banned", "expired", "cancelled":
                throw TripoError.taskFailed(res.status)
            default:
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            }
        }
    }

    /// 下载模型到临时文件，返回本地路径。
    func downloadModel(from url: URL) async throws -> URL {
        let (tmp, resp) = try await session.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TripoError.http(http.statusCode, "下载失败")
        }
        let ext = url.pathExtension.isEmpty ? "glb" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripo_\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - 底层

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw TripoError.decode("无 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TripoError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TripoError.decode("响应非 JSON")
        }
        // Tripo 约定：code == 0 为成功
        if let code = json["code"] as? Int, code != 0 {
            let msg = (json["message"] as? String) ?? "code \(code)"
            throw TripoError.taskFailed(msg)
        }
        return json
    }
}
