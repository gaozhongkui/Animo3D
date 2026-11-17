// Run from the repository root: bash tools/run_user_content_storage_tests.sh

import Foundation
import XCTest

private struct ImportedItem: Codable, Equatable {
    let id: String
    let name: String
    let file: String
}

private final class InterruptedCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at source: URL, to destination: URL) throws {
        if source.lastPathComponent == "second.vrm" {
            // Leave a partial copy just as an interrupted disk operation might.
            try Data("partial".utf8).write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: source, to: destination)
    }
}

final class UserContentStorageTests: XCTestCase {
    private var root: URL!
    private var legacyDirectory: URL { root.appendingPathComponent("Caches/RemoteAssets") }
    private var persistentDirectory: URL { root.appendingPathComponent("Application Support/UserContent") }
    private let indexName = "_user_index.json"
    private let items = [
        ImportedItem(id: "first", name: "First Character", file: "first.vrm"),
        ImportedItem(id: "second", name: "Photo Stage", file: "second.jpg")
    ]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserContentStorageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func storage(fileManager: FileManager = .default) -> UserContentStorage<ImportedItem> {
        UserContentStorage(
            directory: persistentDirectory,
            legacyDirectory: legacyDirectory,
            indexName: indexName,
            fileManager: fileManager,
            fileName: { $0.file }
        )
    }

    private func seedLegacy(_ records: [ImportedItem]) throws {
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        for record in records {
            try Data(record.name.utf8).write(to: legacyDirectory.appendingPathComponent(record.file))
        }
        try JSONEncoder().encode(records).write(to: legacyDirectory.appendingPathComponent(indexName))
    }

    func testMigratesIndexedFilesWithoutMovingRemoteCache() throws {
        try seedLegacy(items)
        let remote = legacyDirectory.appendingPathComponent("dance.vrma")
        try Data("remote dance".utf8).write(to: remote)

        XCTAssertEqual(storage().load(), items)
        for item in items {
            XCTAssertEqual(
                try Data(contentsOf: storage().storedURL(for: item.file)),
                Data(item.name.utf8)
            )
            let legacyFile = legacyDirectory.appendingPathComponent(item.file)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        }
        let legacyIndex = legacyDirectory.appendingPathComponent(indexName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyIndex.path))
        XCTAssertEqual(try Data(contentsOf: remote), Data("remote dance".utf8))
    }

    func testImportsSurviveCacheRemovalAndReload() throws {
        try seedLegacy(items)
        XCTAssertEqual(storage().load(), items)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Caches"))

        XCTAssertEqual(storage().load(), items)
        for item in items {
            XCTAssertEqual(storage().existingURL(for: item.file), storage().storedURL(for: item.file))
        }
    }

    func testInterruptedMigrationKeepsOriginalsAndRetries() throws {
        let records = [items[0], ImportedItem(id: "second", name: "Second", file: "second.vrm")]
        try seedLegacy(records)
        let interrupted = storage(fileManager: InterruptedCopyFileManager())

        XCTAssertEqual(interrupted.load(), records)
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.storedURL(for: indexName).path))
        XCTAssertEqual(
            interrupted.existingURL(for: "second.vrm"),
            legacyDirectory.appendingPathComponent("second.vrm")
        )
        for item in records {
            let legacyFile = legacyDirectory.appendingPathComponent(item.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        }

        XCTAssertEqual(storage().load(), records)
        XCTAssertEqual(try Data(contentsOf: storage().storedURL(for: "second.vrm")), Data("Second".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: persistentDirectory.path)
                .contains { $0.hasPrefix(".migration-") }
        )
    }

    func testDurableIndexPreventsDeletedImportsFromReturning() throws {
        try seedLegacy(items)
        XCTAssertEqual(storage().load(), items)
        try storage().save([])
        // Simulate leftover legacy files from cleanup that could not finish.
        try seedLegacy(items)

        XCTAssertEqual(storage().load(), [])
    }

    func testNewImportRenameAndDeletionPersist() throws {
        let store = storage()
        try store.prepareDirectory()
        let item = items[0]
        try Data("new model".utf8).write(to: store.storedURL(for: item.file))
        try store.save([item])
        XCTAssertEqual(storage().load(), [item])

        let renamed = ImportedItem(id: item.id, name: "Renamed", file: item.file)
        try store.save([renamed])
        XCTAssertEqual(storage().load(), [renamed])

        try store.save([])
        store.removeFile(named: item.file)
        XCTAssertEqual(storage().load(), [])
        XCTAssertNil(store.existingURL(for: item.file))
    }

    func testMissingLegacyFileDoesNotCreateBrokenEntry() throws {
        try seedLegacy(items)
        try FileManager.default.removeItem(at: legacyDirectory.appendingPathComponent(items[1].file))

        XCTAssertEqual(storage().load(), [items[0]])
        XCTAssertEqual(storage().load(), [items[0]])
    }
}

@main
private enum TestRunner {
    static func main() {
        let suite = UserContentStorageTests.defaultTestSuite
        guard suite.testCaseCount == 6 else {
            fatalError("Expected all six user-content regression tests to be discovered")
        }
        suite.run()
        exit(suite.testRun?.hasSucceeded == true ? 0 : 1)
    }
}
