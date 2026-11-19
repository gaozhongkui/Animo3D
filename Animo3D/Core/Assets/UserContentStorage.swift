import Foundation

/// Keeps user imports outside purgeable caches and upgrades the old indexed files safely.
struct UserContentStorage<Item: Codable> {
    let directory: URL
    private let legacyDirectory: URL
    private let indexName: String
    private let fileName: (Item) -> String
    private let fileManager: FileManager

    init(
        directory: URL,
        legacyDirectory: URL,
        indexName: String,
        fileManager: FileManager = .default,
        fileName: @escaping (Item) -> String
    ) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.indexName = indexName
        self.fileManager = fileManager
        self.fileName = fileName
    }

    func prepareDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func storedURL(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// The legacy copy remains readable if a migration could not finish, e.g. on a full disk.
    func existingURL(for name: String) -> URL? {
        let stored = storedURL(for: name)
        if fileManager.fileExists(atPath: stored.path) { return stored }
        let legacy = legacyDirectory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func load() -> [Item] {
        let index = storedURL(for: indexName)
        let legacyIndex = legacyDirectory.appendingPathComponent(indexName)
        // Once a durable index exists it is authoritative, even when empty. Reading an old index
        // again could resurrect imports the user subsequently deleted.
        let isMigrating = !fileManager.fileExists(atPath: index.path)
        let source = isMigrating ? legacyIndex : index
        guard fileManager.fileExists(atPath: source.path) else { return [] }

        do {
            let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: source))
            let available = items.filter { existingURL(for: fileName($0)) != nil }
            do {
                if isMigrating || available.count != items.count {
                    try save(available)
                }
                if isMigrating {
                    // Save copies every surviving file before atomically committing the index.
                    // A failed copy or write never removes the only usable legacy version.
                    try fileManager.removeItem(at: legacyIndex)
                    for item in available {
                        let legacy = legacyDirectory.appendingPathComponent(fileName(item))
                        try? fileManager.removeItem(at: legacy)
                    }
                }
            } catch {
                NSLog(
                    "[UserContentStorage] migration/save failed for %@: %@",
                    indexName,
                    error.localizedDescription
                )
            }
            return available
        } catch {
            NSLog("[UserContentStorage] could not read %@: %@", indexName, error.localizedDescription)
            return []
        }
    }

    func save(_ items: [Item]) throws {
        try prepareDirectory()
        for item in items {
            let name = fileName(item)
            let destination = storedURL(for: name)
            if fileManager.fileExists(atPath: destination.path) { continue }
            // This also completes a previously interrupted migration before new edits are saved.
            let legacy = legacyDirectory.appendingPathComponent(name)
            let temporary = directory.appendingPathComponent(".migration-\(UUID().uuidString)")
            do {
                try fileManager.copyItem(at: legacy, to: temporary)
                try fileManager.moveItem(at: temporary, to: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: storedURL(for: indexName), options: .atomic)
    }

    func removeFile(named name: String) {
        for folder in [directory, legacyDirectory] {
            let file = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            do {
                try fileManager.removeItem(at: file)
            } catch {
                NSLog("[UserContentStorage] could not remove %@: %@", name, error.localizedDescription)
            }
        }
    }
}
