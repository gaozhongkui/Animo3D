//
//  MusicPicker.swift
//  Animo3D
//
//  Dance background music: bundled tracks (Res/music) + local imports (persisted).
//  Data + player + local library + file picker. The UI (the selection step) lives in DanceStudioView.
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine

struct MusicTrack: Identifiable, Hashable {
    let id: String
    let name: String
    /// nil for a catalog track that has not been fetched yet - it is resolved when played.
    let url: URL?
    let asset: AssetRef?

    init(id: String, name: String, url: URL?, asset: AssetRef? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.asset = asset
    }

    /// Catalog tracks plus anything bundled. The catalog states each track's real filename, so there
    /// is no need to try `.mp3` and then `.m4a` and eat a failed round trip on the wrong guess.
    static var presets: [MusicTrack] {
        var out: [MusicTrack] = []
        var seen = Set<String>()

        for m in RemoteAssets.shared.music {
            guard let ref = m.asset else { continue }
            seen.insert(ref.file)
            // 内部 ID 使用小驼峰 (camelCase)
            let camelID = m.key.lowercased().split(separator: "_").enumerated().map { i, word in
                i == 0 ? String(word) : word.capitalized
            }.joined()

            out.append(MusicTrack(id: "remote" + camelID.capitalized,
                                  name: friendly(m.key), // 改为使用 key 匹配，确保 100% 成功
                                  url: RemoteAssets.shared.localURL(for: ref.file),
                                  asset: ref))
        }

        // 扫面本地打包文件
        for ext in ["m4a", "mp3"] {
            for url in Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [] {
                let file = url.lastPathComponent
                guard !seen.contains(file) else { continue }
                let base = url.deletingPathExtension().lastPathComponent
                out.append(MusicTrack(id: file, name: friendly(base), url: url))
            }
        }

        return out.sorted { $0.name < $1.name }
    }

    private static func friendly(_ key: String) -> String {
        // 使用 key 进行精确匹配，返回优雅的标题
        switch key.lowercased() {
        case "sample_beat", "samplebeat":    return "Midnight Pulse"
        case "sample_chill", "samplechill":  return "Azure Horizon"
        case "anime_dance", "animedance":    return "Neon Sakura"
        case "delta_works", "deltaworks":    return "Digital Odyssey"
        default:
            // 兜底逻辑：转为首字母大写的 Title Case
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// Background music player (looping).
final class MusicController: ObservableObject {
    @Published private(set) var current: MusicTrack?
    private var player: AVAudioPlayer?

    func play(_ track: MusicTrack) {
        stop()
        if let url = track.url {
            startPlayback(at: url, track: track)
            return
        }
        guard let asset = track.asset else {
            print("[Music] no source for \(track.name)")
            return
        }
        Task { @MainActor in
            guard let url = try? await RemoteAssets.shared.resolve(asset) else {
                print("[Music] download failed for \(asset.file)")
                return
            }
            self.startPlayback(at: url, track: track)
        }
    }

    private func startPlayback(at url: URL, track: MusicTrack) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.numberOfLoops = -1
            p.isMeteringEnabled = true   // Lets the VFX read the live energy (beat drive)
            p.play()
            player = p
            current = track
        } catch {
            print("[Music] playback failed: \(error.localizedDescription)")
        }
    }

    /// Current instantaneous volume energy (0...1), so the stage VFX can pulse with the beat. Returns 0 when there is no music.
    func currentLevel() -> Float {
        guard let p = player, p.isPlaying else { return 0 }
        p.updateMeters()
        let db = p.averagePower(forChannel: 0)          // Roughly -160...0 dB
        return max(0, min(1, (db + 45) / 45))            // -45dB…0 → 0…1
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
    }
}

/// Locally imported library (persisted to Documents/music).
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
            print("[Music] import failed: \(error.localizedDescription)"); return nil
        }
        reload()
        return tracks.first { $0.url?.lastPathComponent == dst.lastPathComponent }
    }

    func delete(_ track: MusicTrack) {
        guard let url = track.url else { return }   // catalog tracks are not part of the local library
        try? FileManager.default.removeItem(at: url)
        reload()
    }
}

/// Local audio file selection (the Files app, which sidesteps Apple Music DRM).
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
