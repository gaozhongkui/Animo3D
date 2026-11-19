//
//  UsageStats.swift
//  Animo3D
//
//  The numbers on the profile page.
//
//  They used to be `"15"`, `"1.2k"` and `"9"` - written into the layout as string literals, so every
//  user on every device was told they had made 15 videos and collected 1.2k likes. A number a user
//  can check is worse than no number at all: the first time somebody with two recordings reads
//  "15 Works", every other figure on the screen becomes suspect too.
//
//  "Likes" is gone rather than made real. There is nothing in this app that can like anything - no
//  accounts, no server, no social graph - so it was never a statistic, it was decoration. What
//  replaces it is something the app actually knows: how many community models the user has opened.
//
//  Counters live in UserDefaults, which is the right durability for this. Losing them on a
//  reinstall is fine; they describe use of the app, not the user's work.
//

import Foundation

enum UsageStats {
    private static let viewsKey = "stat_community_views"
    private static let firstLaunchKey = "stat_first_launch"

    /// How many community models the user has opened the detail page for. Counted per open rather
    /// than per unique model: it is a measure of browsing, not of a collection.
    static var communityViews: Int {
        UserDefaults.standard.integer(forKey: viewsKey)
    }

    static func recordCommunityView() {
        UserDefaults.standard.set(communityViews + 1, forKey: viewsKey)
    }

    /// Days since first launch, counted in whole days and never less than 1 - a user on their first
    /// day has been here one day, not zero.
    static var daysActive: Int {
        let defaults = UserDefaults.standard
        let first: Date
        if let stored = defaults.object(forKey: firstLaunchKey) as? Date {
            first = stored
        } else {
            first = Date()
            defaults.set(first, forKey: firstLaunchKey)
        }
        let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
        return max(1, days + 1)
    }

    /// How many videos the user has actually recorded.
    static var works: Int { WorksStore.shared.works.count }
}
