//
//  Analytics.swift
//  Animo3D
//
//  Every analytics call in the app goes through here.
//
//  One file rather than `Analytics.logEvent` scattered around, for three reasons that all cost
//  real data when they go wrong:
//
//  - **Event names are a schema.** Firebase creates a new event the first time it sees a name, so
//    `record_start` and `record_started` become two events that each hold half the funnel, and
//    nothing in the build catches it. Here they are an enum, so a typo does not compile.
//  - **Firebase silently drops anything malformed.** Names over 40 characters, names that do not
//    start with a letter, parameter values over 100 characters - all rejected at the SDK boundary
//    with nothing logged in release. `sanitise` clips them instead.
//  - **The reserved prefixes** (`firebase_`, `google_`, `ga_`) are rejected outright. Keeping the
//    names in one list is how that stays true.
//
//  What is NOT here: `app_open`, `session_start`, `screen_view` for UIKit screens, and the install
//  and engagement events. Firebase collects those on its own; logging them again would double the
//  counts.
//

import Foundation
import SwiftUI
import FirebaseCore
import FirebaseAnalytics

/// The app's event vocabulary.
///
/// Not a list of buttons. Each group answers a question somebody will actually ask about this
/// product, and an event only exists because a decision depends on it:
///
///  1. **Can a new user get a video out?** The studio is a four-step wizard, so the funnel is
///     `studio_step` at each one plus `studio_abandoned` carrying the step they left on. Without
///     the abandon event a drop-off is invisible - the step counts alone cannot tell "went back"
///     from "still deciding".
///  2. **What should we make more of?** `character_selected` / `dance_selected` / `music_selected`
///     carry the id. This is the only thing that says which of the 15 characters and 40 dances are
///     worth the pipeline time.
///  3. **Does the content arrive?** Everything this app shows is downloaded - a 7KB index and then
///     17-26MB per character. If the index fails the app is simply empty, and today nobody would
///     know. `catalog_loaded` / `catalog_failed` / `asset_download` make that visible, with the
///     megabytes and milliseconds, because "slow" and "broken" need different fixes.
///  4. **Does AR work in real rooms?** It is the headline feature and the most fragile. Entered ->
///     plane found -> placed is a funnel of its own, and `ar_abandoned` with `placed=no` is the
///     number that says the room beat us.
///  5. **Who can actually record?** We know from measurement that recording costs a second render
///     of the scene, and that older hardware struggles. `device_tier` as a user property plus
///     `record_finished` is what turns that from a hunch into a share of users.
///  6. **Where does money come from?** `paywall_shown` carries its source, so a locked character
///     and the profile button can be told apart.
///
/// Names are snake_case, under 40 characters, and avoid the reserved `firebase_` / `google_` /
/// `ga_` prefixes, which Firebase rejects outright.
enum TrackEvent: String {
    // MARK: Activation funnel
    /// Which of the four studio steps the user is on. One event, `step` as a parameter, so the
    /// funnel reads in order instead of as four unrelated counts.
    case studioStep = "studio_step"
    /// Left the studio without performing. `step` says where.
    case studioAbandoned = "studio_abandoned"
    case performanceStarted = "performance_started"
    case stageReady = "stage_ready"

    // MARK: Content choices
    case characterSelected = "character_selected"
    case danceSelected = "dance_selected"
    case musicSelected = "music_selected"

    // MARK: Recording and output
    case recordStarted = "record_started"
    case recordFinished = "record_finished"
    case exportFinished = "export_finished"
    case workSaved = "work_saved"
    case workShared = "work_shared"
    case workDeleted = "work_deleted"

    // MARK: AR
    case arEntered = "ar_entered"
    case arPlaneFound = "ar_plane_found"
    case arPlaced = "ar_placed"
    case arPlaceMissed = "ar_place_missed"
    case arAbandoned = "ar_abandoned"

    // MARK: Asset delivery
    case catalogLoaded = "catalog_loaded"
    case catalogFailed = "catalog_failed"
    case assetDownload = "asset_download"

    // MARK: Community
    case communityCategory = "community_category"
    case communitySearch = "community_search"
    case communityModelOpened = "community_model_opened"
    case communityModelAR = "community_model_ar"

    // MARK: Money
    case paywallShown = "paywall_shown"
    case lockedItemTapped = "locked_item_tapped"
    case purchaseStarted = "purchase_started"
    case purchaseSucceeded = "purchase_succeeded"
    case purchaseFailed = "purchase_failed"
    case purchaseRestored = "purchase_restored"

    // MARK: Other entry points
    case videoDriveStarted = "video_drive_started"
    case screenView = "screen_shown"
}

enum Track {
    /// Call once, before anything else logs. Safe to call twice; the second call is ignored.
    ///
    /// `FirebaseApp.configure()` reads GoogleService-Info.plist out of the bundle and traps if it
    /// is not there - which is the whole failure mode of "analytics was added and no data arrived",
    /// so it is checked explicitly and reported rather than left to crash a release build.
    static func start() {
        guard FirebaseApp.app() == nil else { return }
        guard Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil else {
            NSLog("[Track] GoogleService-Info.plist is not in the bundle - analytics is off")
            return
        }
        FirebaseApp.configure()
        NSLog("[Track] Firebase configured")
    }

    static func log(_ event: TrackEvent, _ params: [String: Any] = [:]) {
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent(event.rawValue, parameters: params.isEmpty ? nil : sanitise(params))
    }

    /// SwiftUI has no automatic screen tracking - `screen_view` is collected for UIViewControllers
    /// only, and this app is one hosting controller with everything inside it, so without this the
    /// whole product looks like a single screen.
    static func screen(_ name: String) {
        log(.screenView, [AnalyticsParameterScreenName: name])
    }

    /// Whether the user has ever paid. Set once and it rides along with every later event, which is
    /// what makes "do Pro users record more" answerable without a join.
    static func setPro(_ isPro: Bool) {
        guard FirebaseApp.app() != nil else { return }
        Analytics.setUserProperty(isPro ? "pro" : "free", forName: "plan")
    }

    /// Which hardware tier this user is on.
    ///
    /// The recorder renders the scene a second time per frame, and measurement put that at 70ms a
    /// frame before it was reworked - far outside a 30Hz tick on older hardware. Splitting every
    /// funnel by this is what turns "recording is laggy for some people" into a number, and it is
    /// the single most useful property this app can set given what it does.
    static func setDeviceTier() {
        guard FirebaseApp.app() != nil else { return }
        Analytics.setUserProperty(DeviceTier.isLowEnd ? "low" : "high", forName: "device_tier")
    }

    /// Milliseconds since `start`, as an Int, for duration parameters.
    static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    // MARK: - Limits
    //
    // Firebase's own, as of SDK 12: 40 characters for a parameter name, 100 for a string value,
    // 25 parameters per event. Over any of them and the event is dropped, not truncated.

    private static func sanitise(_ params: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in params.prefix(25) {
            let name = String(key.prefix(40))
            if let s = value as? String {
                out[name] = String(s.prefix(100))
            } else if value is NSNumber {
                out[name] = value
            } else {
                out[name] = String(describing: value).prefix(100).description
            }
        }
        return out
    }
}

extension View {
    /// Log a screen the moment it appears. `id` so a screen that is rebuilt for a different subject
    /// - the same detail page for another model - counts as another view rather than one.
    func trackScreen(_ name: String) -> some View {
        onAppear { Track.screen(name) }
    }
}
