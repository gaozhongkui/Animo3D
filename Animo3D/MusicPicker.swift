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
    let url: URL

    /// Bundled tracks: scans the audio inside the app bundle.
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
        case "sample_beat":  return "Sample · Beat"
        case "sample_chill": return "Sample · Chill"
        case "anime_dance":  return "Upbeat · Anime"
        case "delta_works":  return "Electronic · Delta"
        default:             return raw.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Background music player (looping).
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
        return tracks.first { $0.url.lastPathComponent == dst.lastPathComponent }
    }

    func delete(_ track: MusicTrack) {
        try? FileManager.default.removeItem(at: track.url)
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
