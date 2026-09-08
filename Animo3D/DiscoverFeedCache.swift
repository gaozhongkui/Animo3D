//
//  DiscoverFeedCache.swift
//  Animo3D
//
//  Remembers the first page of the discover feed, per query and category.
//
//  Why: `DiscoverViewControllerRepresentable.makeUIViewController` builds a fresh
//  `DiscoverViewController` every time SwiftUI re-creates the tab, and `loadInitialData()` opened by
//  clearing the array and reloading an empty grid before it even sent the request. So every switch
//  onto the tab was a blank screen with a spinner, showing content the user had already seen a
//  moment earlier.
//
//  Two levels, because the two situations are different:
//    - memory, which makes a tab switch inside one session instant
//    - disk, so the first switch after a relaunch also has something to show
//
//  Only the first page is kept, and only the first `pageLimit` items of it: this exists to fill the
//  screen immediately, not to reproduce an entire scroll position. The live request always runs and
//  always replaces what is shown - the cache decides what the user looks at *while* it runs, never
//  what they end up with.
//

import Foundation

struct DiscoverPage: Codable {
    let models: [SketchfabModel]
    let nextUrl: String?
    let savedAt: Date
}

final class DiscoverFeedCache {
    static let shared = DiscoverFeedCache()

    /// Enough to fill the grid a couple of screens deep.
    private static let pageLimit = 40

    private let lock = NSLock()
    private var memory: [String: DiscoverPage] = [:]

    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("discover_feed", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// One cache slot per (query, category) pair - a search and a category browse are different
    /// lists, and showing one while loading the other would be worse than showing nothing.
    static func key(query: String?, category: String?) -> String {
        let q = (query ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let c = (category ?? "").lowercased()
        return "\(q.isEmpty ? "-" : q)|\(c.isEmpty ? "-" : c)"
    }

    private func file(for key: String) -> URL {
        // The key goes into a file name, so anything that is not safe there is folded away.
        let safe = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    func page(for key: String) -> DiscoverPage? {
        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let data = try? Data(contentsOf: file(for: key)),
              let page = try? JSONDecoder().decode(DiscoverPage.self, from: data) else { return nil }
        lock.lock(); memory[key] = page; lock.unlock()
        return page
    }

    func store(models: [SketchfabModel], nextUrl: String?, for key: String) {
        guard !models.isEmpty else { return }
        let page = DiscoverPage(models: Array(models.prefix(Self.pageLimit)),
                                nextUrl: nextUrl, savedAt: Date())
        lock.lock(); memory[key] = page; lock.unlock()

        // Off the caller's thread: this runs right after a fetch lands, which is the same moment the
        // grid is reloading.
        let url = file(for: key)
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(page) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
