//
//  TripoClient.swift
//  Animo3D
//
//  Tripo3D OpenAPI Client: Upload image -> Create image_to_model task -> Polling -> Get model download URL.
//  Documentation: https://docs.tripo3d.ai (Base URL: https://api.tripo3d.ai/v2/openapi, Bearer Authentication)
//
//  Note: Field names are organized based on official documentation; actual debugging is needed after obtaining your API Key.
//

import Foundation

enum TripoError: LocalizedError {
    case http(Int, String)
    case decode(String)
    case taskFailed(String)
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .decode(let m): return "Parse failed: \(m)"
        case .taskFailed(let m): return "Task failed: \(m)"
        }
    }
}

struct TripoResult {
    let status: String        // queued / running / success / failed ...
    let progress: Int
    let modelURL: URL?        // Download URL of the generated model (on success)
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

    /// Upload image, returns file_token (used for referencing the image in subsequent tasks).
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
            throw TripoError.decode("Upload response is missing image_token")
        }
        return token
    }

    /// Create image_to_model task, returns task_id.
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
            throw TripoError.decode("Create-task response is missing task_id")
        }
        return taskId
    }

    /// Auto-Rig for the generated model. spec=mixamo makes bone names compatible with Mixamo,
    /// allowing direct reuse of existing Mixamo retargeting mappings. Returns new task_id.
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
            throw TripoError.decode("Rig-task response is missing task_id")
        }
        return taskId
    }

    /// Query task status.
    func getTask(_ taskId: String) async throws -> TripoResult {
        let r = request("task/\(taskId)", method: "GET")
        let json = try await send(r)
        guard let d = json["data"] as? [String: Any] else {
            throw TripoError.decode("Task response is missing data")
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

    /// Poll until success/failure. progress callback used for updating UI.
    func waitForCompletion(taskId: String,
                           onProgress: @escaping (TripoResult) -> Void) async throws -> URL {
        while true {
            let res = try await getTask(taskId)
            await MainActor.run { onProgress(res) }
            switch res.status {
            case "success":
                if let url = res.modelURL { return url }
                throw TripoError.taskFailed("Task succeeded but returned no model URL")
            case "failed", "banned", "expired", "cancelled":
                throw TripoError.taskFailed(res.status)
            default:
                try await Task.sleep(nanoseconds: 3_000_000_000) // 3s
            }
        }
    }

    /// Download model to temporary file, returns local path.
    func downloadModel(from url: URL) async throws -> URL {
        let (tmp, resp) = try await session.download(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TripoError.http(http.statusCode, "Download failed")
        }
        let ext = url.pathExtension.isEmpty ? "glb" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("tripo_\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: - Low-level

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw TripoError.decode("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TripoError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TripoError.decode("Response is not JSON")
        }
        // Tripo convention: code == 0 means success
        if let code = json["code"] as? Int, code != 0 {
            let msg = (json["message"] as? String) ?? "code \(code)"
            throw TripoError.taskFailed(msg)
        }
        return json
    }
}
