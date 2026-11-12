import Foundation

/// The US time zones a rep can call into.
enum CallZone: String, CaseIterable, Identifiable {
    case eastern, central, mountain, pacific, alaska, hawaii

    var id: String { rawValue }

    var label: String {
        switch self {
        case .eastern: return "Eastern"
        case .central: return "Central"
        case .mountain: return "Mountain"
        case .pacific: return "Pacific"
        case .alaska: return "Alaska"
        case .hawaii: return "Hawaii"
        }
    }

    var timeZone: TimeZone {
        let name: String
        switch self {
        case .eastern: name = "America/New_York"
        case .central: name = "America/Chicago"
        case .mountain: name = "America/Denver"
        case .pacific: name = "America/Los_Angeles"
        case .alaska: name = "America/Anchorage"
        case .hawaii: name = "Pacific/Honolulu"
        }
        return TimeZone(identifier: name) ?? .current
    }

    /// The time there right now, like "2:15 PM".
    var timeNow: String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return Date().formatted(style)
    }

    // MARK: Working out someone's time zone

    /// The time zone from what's on the Salesforce record: the state first, then the phone's
    /// area code. nil = the record doesn't say (no state and no US number, or another country).
    static func of(state: String?, country: String?, phones: [String?]) -> CallZone? {
        let c = clean(country)
        if !c.isEmpty, !usNames.contains(c) { return nil }
        let codes = phones.compactMap(areaCode)
        if let st = stateCode(state) {
            // A few states have two time zones. A number from the same state says which side.
            if let code = codes.first(where: { areaCodeStates[$0] == st }) { return zone(areaCode: code) }
            return stateZones[st]
        }
        return codes.lazy.compactMap(zone(areaCode:)).first
    }

    /// "OR", "Oregon" or " oregon " -> "OR". nil when it isn't a US state.
    static func stateCode(_ state: String?) -> String? {
        let s = clean(state).replacingOccurrences(of: ".", with: "")
        if s.isEmpty { return nil }
        let upper = s.uppercased()
        if stateZones[upper] != nil { return upper }
        return stateNames[s]
    }

    /// The area code of a US number. nil for short or foreign numbers.
    static func areaCode(_ phone: String?) -> String? {
        guard let phone else { return nil }
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("+"), !trimmed.hasPrefix("+1") { return nil }
        var digits = trimmed.filter(\.isNumber)
        if digits.count >= 11, digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count >= 10 else { return nil }
        return String(digits.prefix(3))
    }

    static func zone(areaCode code: String) -> CallZone? {
        if let special = areaCodeOverrides[code] { return special }
        return areaCodeStates[code].flatMap { stateZones[$0] }
    }

    private static func clean(_ s: String?) -> String {
        (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let usNames: Set<String> = [
        "us", "usa", "u.s.", "u.s.a.", "united states", "united states of america", "america",
    ]

    /// Each state's time zone (the one most of its people live in, for states with two).
    static let stateZones: [String: CallZone] = {
        var out: [String: CallZone] = [:]
        let groups: [(CallZone, String)] = [
            (.eastern, "CT DE DC FL GA IN KY ME MD MA MI NH NJ NY NC OH PA RI SC VT VA WV"),
            (.central, "AL AR IL IA KS LA MN MS MO NE ND OK SD TN TX WI"),
            (.mountain, "AZ CO ID MT NM UT WY"),
            (.pacific, "CA NV OR WA"),
            (.alaska, "AK"),
            (.hawaii, "HI"),
        ]
        for (zone, states) in groups {
            for st in states.split(separator: " ") { out[String(st)] = zone }
        }
        return out
    }()

    private static let stateNames: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "district of columbia": "DC",
        "washington dc": "DC", "washington, dc": "DC", "florida": "FL", "georgia": "GA", "hawaii": "HI",
        "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS", "kentucky": "KY",
        "louisiana": "LA", "maine": "ME", "maryland": "MD", "massachusetts": "MA", "michigan": "MI",
        "minnesota": "MN", "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE",
        "nevada": "NV", "new hampshire": "NH", "new jersey": "NJ", "new mexico": "NM", "new york": "NY",
        "north carolina": "NC", "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR",
        "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC", "south dakota": "SD",
        "tennessee": "TN", "texas": "TX", "utah": "UT", "vermont": "VT", "virginia": "VA",
        "washington": "WA", "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
    ]

    /// Area codes on the other side of a two-zone state.
    private static let areaCodeOverrides: [String: CallZone] = [
        "850": .central, "448": .central,   // Florida panhandle
        "915": .mountain,                   // El Paso, Texas
        "423": .eastern, "865": .eastern,   // East Tennessee
        "270": .central, "364": .central,   // Western Kentucky
        "219": .central,                    // Northwest Indiana
    ]

    /// Which state each US area code belongs to.
    private static let areaCodeStates: [String: String] = {
        let byState: [String: String] = [
            "AL": "205 251 256 334 659 938",
            "AK": "907",
            "AZ": "480 520 602 623 928",
            "AR": "327 479 501 870",
            "CA": "209 213 279 310 323 341 350 369 408 415 424 442 510 530 559 562 619 626 628 650 657 661 669 707 714 738 747 760 805 818 820 831 840 858 909 916 925 949 951",
            "CO": "303 719 720 970 983",
            "CT": "203 475 860 959",
            "DE": "302",
            "DC": "202 771",
            "FL": "239 305 321 324 352 386 407 448 561 645 656 689 727 728 754 772 786 813 850 863 904 941 954",
            "GA": "229 404 470 478 678 706 762 770 912 943",
            "HI": "808",
            "ID": "208 986",
            "IL": "217 224 309 312 331 447 464 618 630 708 730 773 779 815 847 861 872",
            "IN": "219 260 317 463 574 765 812 930",
            "IA": "319 515 563 641 712",
            "KS": "316 620 785 913",
            "KY": "270 364 502 606 859",
            "LA": "225 318 337 504 985",
            "ME": "207",
            "MD": "227 240 301 410 443 667",
            "MA": "339 351 413 508 617 774 781 857 978",
            "MI": "231 248 269 313 517 586 616 679 734 810 906 947 989",
            "MN": "218 320 507 612 651 763 924 952",
            "MS": "228 601 662 769",
            "MO": "235 314 417 557 573 636 660 816 975",
            "MT": "406",
            "NE": "308 402 531",
            "NV": "702 725 775",
            "NH": "603",
            "NJ": "201 551 609 640 732 848 856 862 908 973",
            "NM": "505 575",
            "NY": "212 315 329 332 347 363 516 518 585 607 624 631 646 680 716 718 838 845 914 917 929 934",
            "NC": "252 336 472 704 743 828 910 919 980 984",
            "ND": "701",
            "OH": "216 220 234 283 326 330 380 419 436 440 513 567 614 740 937",
            "OK": "405 539 572 580 918",
            "OR": "458 503 541 971",
            "PA": "215 223 267 272 412 445 484 570 582 610 717 724 814 835 878",
            "RI": "401",
            "SC": "803 821 839 843 854 864",
            "SD": "605",
            "TN": "423 615 629 731 865 901 931",
            "TX": "210 214 254 281 325 346 361 409 430 432 469 512 621 682 713 726 737 806 817 830 832 903 915 936 940 945 956 972 979",
            "UT": "385 435 801",
            "VT": "802",
            "VA": "276 434 540 571 686 703 757 804 826 948",
            "WA": "206 253 360 425 509 564",
            "WV": "304 681",
            "WI": "262 274 414 534 608 715 920",
            "WY": "307",
        ]
        var out: [String: String] = [:]
        for (state, codes) in byState {
            for code in codes.split(separator: " ") { out[String(code)] = state }
        }
        return out
    }()
}

/// "Only call people in this time zone." Works on both call lists.
///
/// A person whose Salesforce record says where they are (state, or a US phone number) is left
/// out when they're in another time zone. A record that says nothing stays on the list: there's
/// nothing to filter on. Time zones are remembered, so the filter works the moment the app opens.
enum TimeZoneFilter {
    private static var d: UserDefaults { .standard }

    /// The time zone to call. nil = everyone.
    static var selected: CallZone? {
        get { d.string(forKey: PrefKey.timeZoneFilter).flatMap(CallZone.init(rawValue:)) }
        set {
            if let newValue { d.set(newValue.rawValue, forKey: PrefKey.timeZoneFilter) }
            else { d.removeObject(forKey: PrefKey.timeZoneFilter) }
        }
    }

    /// With all time zones: call the East Coast first, then Central, Mountain, Pacific, Alaska, Hawaii.
    /// People whose record doesn't say come last. Follow-ups still come before new people.
    static var eastCoastFirst: Bool {
        get { d.bool(forKey: PrefKey.eastCoastFirst) }
        set { d.set(newValue, forKey: PrefKey.eastCoastFirst) }
    }

    /// Where they go in East Coast first order (0 = Eastern; unknown last).
    static func eastRank(_ id: String) -> Int {
        guard let zone = zone(of: id) else { return CallZone.allCases.count }
        return CallZone.allCases.firstIndex(of: zone) ?? CallZone.allCases.count
    }

    /// The list in East Coast first order when that's on (stable: same zone keeps list order).
    static func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
        guard eastCoastFirst else { return items }
        return items.enumerated()
            .sorted { (eastRank(id($0.element)), $0.offset) < (eastRank(id($1.element)), $1.offset) }
            .map(\.element)
    }

    /// Record Id (first 15 characters) -> time zone. "" = looked up, the record doesn't say.
    private static var zones: [String: String] = [:]
    /// Looked up since the app opened (older answers come from the saved copy).
    private static var fresh: Set<String> = []
    private static var loaded = false
    private static var dirty = false
    /// Lists load in the background while the screen reads time zones: one at a time.
    private static let lock = NSLock()

    private static func key(_ id: String) -> String { String(id.prefix(15)) }

    private static func loadSaved() {
        guard !loaded else { return }
        loaded = true
        zones = (d.dictionary(forKey: PrefKey.leadTimeZones) as? [String: String]) ?? [:]
    }

    /// Their time zone, if the record says. nil = unknown.
    static func zone(of id: String) -> CallZone? {
        lock.withLock {
            loadSaved()
            return zones[key(id)].flatMap(CallZone.init(rawValue:))
        }
    }

    /// False only when the filter is on and they're known to be in another time zone.
    static func allows(_ id: String) -> Bool {
        guard let want = selected, let theirs = zone(of: id) else { return true }
        return theirs == want
    }

    /// Why the filter says not to call them, in plain words. nil = OK.
    static func why(_ id: String) -> String? {
        guard let want = selected, let theirs = zone(of: id), theirs != want else { return nil }
        return "They're in \(theirs.label) time. You're only calling \(want.label)."
    }

    /// Takes the time zone from a record Salesforce sent back (a Lead or Contact with its
    /// state, country and phone fields). Call `save()` after the last one.
    static func learn(_ r: [String: Any]) {
        guard let id = r["Id"] as? String else { return }
        let account = r["Account"] as? [String: Any]
        func text(_ names: String...) -> String? {
            for name in names {
                if let v = r[name] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
            }
            return nil
        }
        let state = text("State", "MailingState") ?? (account?["BillingState"] as? String)
        let country = text("Country", "MailingCountry")
        let found = CallZone.of(state: state, country: country,
                                phones: [r["MobilePhone"] as? String, r["Phone"] as? String])
        let value = found?.rawValue ?? ""
        let k = key(id)
        lock.withLock {
            loadSaved()
            fresh.insert(k)
            if zones[k] != value {
                zones[k] = value
                dirty = true
            }
        }
    }

    static func save() {
        let changed: [String: String]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return zones
        }
        if let changed { d.set(changed, forKey: PrefKey.leadTimeZones) }
    }

    /// Looks up the time zone of everyone on a list (200 at a time), once each time the app runs.
    static func load(ids: [String], object: String) async {
        guard Salesforce.isConnected, ["Lead", "Contact"].contains(object) else { return }
        let known = lock.withLock { fresh }
        let todo = ids.filter { !known.contains(key($0)) && $0.allSatisfy { $0.isLetter || $0.isNumber } }
        guard !todo.isEmpty else { return }
        let fields = object == "Lead"
            ? "Id, MobilePhone, Phone, State, Country"
            : "Id, MobilePhone, Phone, MailingState, MailingCountry, Account.BillingState"
        for start in stride(from: 0, to: todo.count, by: 200) {
            let list = todo[start..<min(start + 200, todo.count)].map { "'\($0)'" }.joined(separator: ",")
            guard let found = try? await Salesforce.query("SELECT \(fields) FROM \(object) WHERE Id IN (\(list))") else {
                ActivityLog.problem("Time zones: couldn't load them from Salesforce")
                continue
            }
            for r in found { learn(r) }
        }
        save()
    }

    /// People on this list the filter is holding back (they'd be called today in another time zone).
    static func heldBack(_ ids: [String]) -> Int {
        guard selected != nil else { return 0 }
        return ids.filter { !allows($0) && CalledToday.isCallable($0, anyTimeZone: true) }.count
    }
}
