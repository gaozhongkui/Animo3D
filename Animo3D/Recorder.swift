//
//  Recorder.swift
//  Animo3D
//
//  Screen recording (ReplayKit) + creation storage + sharing.
//  Note: ReplayKit cannot run in the Simulator, so recording has to be verified on a physical device.
//

import SwiftUI
import ReplayKit
import AVFoundation
import UIKit
import Combine

/// Screen recording. It captures the current screen (the dancing character).
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var lastError: String?
    private let rec = RPScreenRecorder.shared()

    func start() {
        guard rec.isAvailable else { lastError = L("Screen recording isn't supported here (not available in the Simulator)"); return }
        rec.isMicrophoneEnabled = false
        rec.startRecording { [weak self] err in
            DispatchQueue.main.async {
                if let err { self?.lastError = err.localizedDescription }
                self?.isRecording = (err == nil)
            }
        }
    }

    /// Stops and hands the video to completion (a temporary file URL).
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

/// Creation library: mp4 files stored under Documents/works.
final class WorksStore: ObservableObject {
    static let shared = WorksStore()
    @Published var works: [URL] = []

    private var dir: URL {
        guard let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Extremely unlikely: the documents directory is unreachable. Fall back to the temporary directory instead of crashing.
            return FileManager.default.temporaryDirectory.appendingPathComponent("works")
        }
        let worksDir = d.appendingPathComponent("works", isDirectory: true)
        try? FileManager.default.createDirectory(at: worksDir, withIntermediateDirectories: true)
        return worksDir
    }

    init() { reload() }

    func reload() {
        // Make sure UI properties are updated on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.reload() }
            return
        }

        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []

        // Sort first and assign afterwards, so works cannot be modified externally mid-sort
        let sortedWorks = items.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a > b
        }
        self.works = sortedWorks
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

/// System share sheet.
/// A just-finished recording, so it can drive a `fullScreenCover(item:)`.
struct FinishedWork: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
