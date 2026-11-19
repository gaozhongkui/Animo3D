import Foundation

extension RemoteAssets {
    var proContentAccess: ProContentAccess {
        ProContentAccess(
            characterIDs: characters.map(\.id),
            danceIDs: dances.map(\.id),
            importedCharacterIDs: Set(userCharacters.map(\.id)),
            builtInCharacterID: builtIn?.character,
            builtInDanceID: builtIn?.dance
        )
    }
}
