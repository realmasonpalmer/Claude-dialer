import Foundation

/// Every saved setting's name in one place, so a typo can't quietly break a setting.
/// The stored names never change (changing one would lose the rep's saved value).
enum PrefKey {
    static let goalCardOpen = "goalCardOpen"
    static let statusCardOpen = "statusCardOpen"
    static let aircallNumberID = "aircallNumberID"
    static let aircallShown = "aircallShown"
    static let aircallUserID = "aircallUserID"
    static let appPhone = "appPhone"
    static let audioCheckPassed = "audioCheckPassed"
    static let backboneCampaignAdded = "backboneCampaignAdded"
    static let bookingCalendars = "bookingCalendars"
    static let bookingEndHour = "bookingEndHour"
    static let bookingMinutes = "bookingMinutes"
    static let bookingStartHour = "bookingStartHour"
    static let callList = "callList"
    static let callListIndex = "callListIndex"
    static let callListKey = "callListKey"
    static let calledDay = "calledDay"
    static let calledToday = "calledToday"
    static let coachBuiltInMic = "coachBuiltInMic"
    static let coachSpeed = "coachSpeed"
    static let doubleTap = "doubleTap"
    static let hangUpPhoneTrees = "hangUpPhoneTrees"
    static let installedSHA = "installedSHA"
    static let labAnalyzedAt = "labAnalyzedAt"
    static let learnFromCalls = "learnFromCalls"
    static let maxDials = "maxDials"
    static let nextDials = "nextDials"
    static let openerIndex = "openerIndexV2"
    static let openerScores = "openerScores"
    static let repName = "repName"
    static let rotateOpeners = "rotateOpeners"
    static let scriptOutlineOpen = "scriptOutlineOpen"
    static let selectedCampaign = "selectedCampaign"
    static let sfCalledDay = "sfCalledDay"
    static let sfCalledToday = "sfCalledToday"
    static let sfListView = "sfListView"
    static let sfLoginHost = "sfLoginHost"
    static let showTouchpoints = "showTouchpoints"
    static let touchpointsOpen = "touchpointsOpen"
    static let touchpointsPeriod = "touchpointsPeriod"
    static let wholeLine = "wholeLine"
}

/// Settings the code reads directly, with their defaults.
enum Prefs {
    private static var d: UserDefaults { .standard }

    /// The rep's first name, trimmed ("" if not set).
    static var repName: String { (d.string(forKey: PrefKey.repName) ?? "").trimmingCharacters(in: .whitespaces) }
    /// After Next, dial the next person by itself.
    static var autoDial: Bool {
        get { d.object(forKey: PrefKey.nextDials) as? Bool ?? true }
        set { d.set(newValue, forKey: PrefKey.nextDials) }
    }
    /// Call each person twice in a row when the first try isn't answered.
    static var doubleTap: Bool {
        get { d.object(forKey: PrefKey.doubleTap) as? Bool ?? true }
        set { d.set(newValue, forKey: PrefKey.doubleTap) }
    }
    /// Show a line once it's whole, not word by word.
    static var wholeLine: Bool { d.object(forKey: PrefKey.wholeLine) as? Bool ?? true }
    /// Old phone tree behavior: disqualify and hang up.
    static var hangUpPhoneTrees: Bool { d.bool(forKey: PrefKey.hangUpPhoneTrees) }
    /// Use the Mac's built-in mic for the rep's side.
    static var builtInMic: Bool { d.object(forKey: PrefKey.coachBuiltInMic) as? Bool ?? true }
}
