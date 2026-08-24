//
//  Recorder.swift
//  Animo3D
//
//  录屏(ReplayKit) + 作品存储 + 分享。
//  注意：ReplayKit 无法在模拟器运行，录制需真机验证。
//

import SwiftUI
import ReplayKit
import AVFoundation
import UIKit
import Combine

/// 屏幕录制。录制的是当前屏幕画面（角色跳舞）。
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var lastError: String?
    private let rec = RPScreenRecorder.shared()

    func start() {
        guard rec.isAvailable else { lastError = "此设备/环境不支持录屏（模拟器不支持）"; return }
        rec.isMicrophoneEnabled = false
        rec.startRecording { [weak self] err in
            DispatchQueue.main.async {
                if let err { self?.lastError = err.localizedDescription }
                self?.isRecording = (err == nil)
            }
        }
    }

    /// 停止并把视频交给 completion（临时文件 URL）。
    func stop(completion: @escaping (URL?) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec_\(UUID().uuidString).mp4")
        rec.stopRecording(withOutput: tmp) { [weak self] err in
            DispatchQueue.main.async {
                self?.isRecording = false
                if let err { self?.lastError = err.localizedDescription; completion(nil) }
                else { completion(tmp) }
            }
        }
    }
}

/// 作品库：保存在 Documents/works 下的 mp4。
final class WorksStore: ObservableObject {
    static let shared = WorksStore()
    @Published var works: [URL] = []

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("works", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() { reload() }

    func reload() {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        works = items.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a > b
        }
    }

    @discardableResult
    func add(from tmp: URL) -> URL? {
        let dest = dir.appendingPathComponent("work_\(UUID().uuidString).mp4")
        do { try FileManager.default.moveItem(at: tmp, to: dest); reload(); return dest }
        catch { return nil }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    func thumbnail(for url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let t = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: t, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 系统分享面板。
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
