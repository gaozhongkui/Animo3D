//
//  Recorder.swift
//  Animo3D
//
//  Where finished recordings live, and how they leave the app.
//
//  The file is named after a `Recorder` class that used to be here and is gone: it wrapped
//  ReplayKit, which records the whole screen including the app's own controls, and could not hand
//  back frames to watermark. `SceneViewRecorder` replaced it - per-frame `snapshot()` of the scene
//  view, watermark burned in - and nothing referenced the ReplayKit path any more.
//

import SwiftUI
import AVFoundation
import LinkPresentation
import UIKit
import Combine

/// Screen recording. It captures the current screen (the dancing character).
final class WorksStore: ObservableObject {
    static let shared = WorksStore()
    @Published var works: [URL] = []

    private let directory: URL
    private let draftsDirectory: URL
    private let fileManager: FileManager

    init(
        directory: URL? = nil,
        draftsDirectory: URL = RecordingStorage.draftsDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("works", isDirectory: true)
        self.draftsDirectory = draftsDirectory
        self.fileManager = fileManager
        reload()
    }

    func reload() {
        // Make sure UI properties are updated on the main thread
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.reload() }
            return
        }

        recoverCompletedRecordings()
        let items = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        // Sort first and assign afterwards, so works cannot be modified externally mid-sort
        let sortedWorks = items.filter { $0.pathExtension == "mp4" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return a > b
        }
        self.works = sortedWorks
    }

    @discardableResult
    func add(from source: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent.hasPrefix("work_")
            ? source.deletingPathExtension().lastPathComponent + ".mp4"
            : "work_\(UUID().uuidString).mp4"
        let destination = directory.appendingPathComponent(name)
        if source.standardizedFileURL == destination.standardizedFileURL {
            guard fileManager.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            reload()
            return destination
        }
        // Recovery may already have moved this same completed capture during the first reload.
        if !fileManager.fileExists(atPath: source.path), fileManager.fileExists(atPath: destination.path) {
            reload()
            return destination
        }
        try fileManager.moveItem(at: source, to: destination)
        reload()
        return destination
    }

    private func recoverCompletedRecordings() {
        guard let drafts = try? fileManager.contentsOfDirectory(
            at: draftsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for draft in drafts where draft.pathExtension == "mp4" {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.moveItem(
                    at: draft,
                    to: directory.appendingPathComponent(draft.lastPathComponent)
                )
            } catch {
                // A full disk or unavailable directory must never delete the only recorded copy.
                NSLog("[WorksStore] recording recovery failed: %@", error.localizedDescription)
            }
        }
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

/// A recording handed to the share sheet with its preview already made.
///
/// `UIActivityViewController(activityItems: [movieURL])` stalls for a beat before it appears, and
/// the stall is the sheet building its own header preview: it decodes a frame out of the movie to
/// show a thumbnail, on the main thread, while the user looks at an unresponsive button. The app
/// already has a thumbnail for every recording, so the sheet is given one instead of made to
/// produce a second.
///
/// The URL still goes through as the shared item, so Photos, Messages and AirDrop receive the real
/// file exactly as before - only the preview is pre-supplied.
final class VideoShareItem: NSObject, UIActivityItemSource {
    private let url: URL
    private let title: String
    private let thumbnail: UIImage?

    init(url: URL, title: String, thumbnail: UIImage?) {
        self.url = url
        self.title = title
        self.thumbnail = thumbnail
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }

    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }

    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        if let thumbnail { metadata.imageProvider = NSItemProvider(object: thumbnail) }
        return metadata
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
