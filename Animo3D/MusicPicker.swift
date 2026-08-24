//
//  MusicPicker.swift
//  Animo3D
//
//  跳舞背景音乐：内置曲目(Res/music) + 本地导入(持久保存)。
//  数据 + 播放器 + 本地曲库 + 文件选择器。UI(选择步骤)在 DanceStudioView。
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine

struct MusicTrack: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL

    /// 内置曲目：扫描 App 包内音频。
    static var presets: [MusicTrack] {
        var out: [MusicTrack] = []
        for ext in ["m4a", "mp3"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                let base = url.deletingPathExtension().lastPathComponent
                out.append(MusicTrack(id: url.lastPathComponent, name: friendly(base), url: url))
            }
        }
        return out.sorted { $0.name < $1.name }
    }

    private static func friendly(_ raw: String) -> String {
        switch raw {
        case "sample_beat":  return "示例 · 节奏"
        case "sample_chill": return "示例 · 舒缓"
        default:             return raw.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// 背景音乐播放器（循环）。
final class MusicController: ObservableObject {
    @Published private(set) var current: MusicTrack?
    private var player: AVAudioPlayer?

    func play(_ track: MusicTrack) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: track.url)
            p.numberOfLoops = -1
            p.play()
            player = p
            current = track
        } catch {
            print("[Music] 播放失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
    }
}

/// 本地导入曲库（持久化到 Documents/music）。
final class LocalMusicStore: ObservableObject {
    static let shared = LocalMusicStore()
    @Published private(set) var tracks: [MusicTrack] = []

    private let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("music", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        tracks = files
            .filter { ["m4a", "mp3", "wav", "aac"].contains($0.pathExtension.lowercased()) }
            .map { MusicTrack(id: "local_" + $0.lastPathComponent,
                              name: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.name < $1.name }
    }

    @discardableResult
    func importFile(from url: URL) -> MusicTrack? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let dst = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.copyItem(at: url, to: dst) } catch {
            print("[Music] 导入失败: \(error.localizedDescription)"); return nil
        }
        reload()
        return tracks.first { $0.url.lastPathComponent == dst.lastPathComponent }
    }

    func delete(_ track: MusicTrack) {
        try? FileManager.default.removeItem(at: track.url)
        reload()
    }
}

/// 本地音频文件选择（"文件" App，避开 Apple Music DRM）。
struct AudioDoc: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
