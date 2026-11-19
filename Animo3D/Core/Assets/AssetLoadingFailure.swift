import Foundation

struct AssetLoadingFailure: Error, Equatable {
    enum Resource { case character, dance }
    enum Reason { case offline, timedOut, unavailable, download, invalid, rendering }

    let resource: Resource
    let reason: Reason

    var title: String {
        resource == .character ? "Couldn't load this model" : "Couldn't load this dance"
    }

    var message: String {
        switch reason {
        case .offline:
            return "You're offline. Connect to the internet and try again."
        case .timedOut:
            return "The download took too long. Please try again."
        case .unavailable:
            return "This content is unavailable. Try again later or choose something else."
        case .download:
            return "The assets couldn't be downloaded. Check your connection and try again."
        case .invalid:
            return resource == .character
                ? "This model couldn't be opened. Try again or choose another character."
                : "This dance couldn't be opened. Try again or choose another dance."
        case .rendering:
            return "The scene didn't finish loading. Try again or choose another character."
        }
    }

    static func download(_ error: Error, resource: Resource) -> Self {
        let reason: Reason
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            reason = .offline
        case .timedOut:
            reason = .timedOut
        default:
            reason = .download
        }
        return Self(resource: resource, reason: reason)
    }
}
