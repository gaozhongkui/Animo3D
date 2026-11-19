import Foundation

/// Access is based on the full catalog, never the visible grid or a filtered dance category.
nonisolated struct ProContentAccess {
    static let freeCharacterCount = 3
    static let freeDanceCount = 6

    let freeCharacterIDs: [String]
    let freeDanceIDs: [String]
    private let characterIDs: Set<String>
    private let danceIDs: Set<String>
    private let importedCharacterIDs: Set<String>

    init(
        characterIDs: [String],
        danceIDs: [String],
        importedCharacterIDs: Set<String> = [],
        builtInCharacterID: String? = nil,
        builtInDanceID: String? = nil
    ) {
        self.characterIDs = Set(characterIDs)
        self.danceIDs = Set(danceIDs)
        self.importedCharacterIDs = importedCharacterIDs
        freeCharacterIDs = Self.freeIDs(
            in: characterIDs.filter { !importedCharacterIDs.contains($0) },
            preferred: builtInCharacterID,
            limit: Self.freeCharacterCount
        )
        freeDanceIDs = Self.freeIDs(in: danceIDs, preferred: builtInDanceID, limit: Self.freeDanceCount)
    }

    func canUseCharacter(_ id: String, isPro: Bool) -> Bool {
        guard !id.isEmpty else { return false }
        if importedCharacterIDs.contains(id) { return true }
        guard characterIDs.contains(id) else { return false }
        return isPro || freeCharacterIDs.contains(id)
    }

    func canUseDance(_ id: String, isPro: Bool) -> Bool {
        guard !id.isEmpty else { return false }
        guard danceIDs.contains(id) else { return false }
        return isPro || freeDanceIDs.contains(id)
    }

    private static func freeIDs(in orderedIDs: [String], preferred: String?, limit: Int) -> [String] {
        var candidates = orderedIDs
        if let preferred, orderedIDs.contains(preferred) {
            candidates = [preferred] + orderedIDs
        }
        var seen = Set<String>()
        return Array(candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(limit))
    }
}
