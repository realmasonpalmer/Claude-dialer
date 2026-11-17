import Foundation

/// "Mobile numbers only" on a call list: people with no Mobile in Salesforce (office Phone only)
/// are skipped for that call list. Set per call list in Edit call list.
enum MobileOnly {
    /// The call list in use now (set by the coach).
    static var campaignID: UUID?

    static func key(_ id: UUID) -> String { "mobileOnly-" + id.uuidString }
    static func isOn(for id: UUID) -> Bool { UserDefaults.standard.bool(forKey: key(id)) }
    static var on: Bool { campaignID.map(isOn(for:)) ?? false }

    /// People we looked up who have no Mobile.
    private static var noMobile: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "noMobileIDs") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "noMobileIDs") }
    }

    static func record(_ id: String, mobile: String?) {
        let k = String(id.prefix(15))
        let has = !(mobile?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        var set = noMobile
        if has { set.remove(k) } else { set.insert(k) }
        noMobile = set
    }

    /// Skip this person on the current call list.
    static func excluded(_ id: String) -> Bool { on && noMobile.contains(String(id.prefix(15))) }
}
