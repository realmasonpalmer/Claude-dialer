import Foundation

/// North American time zones, worked out from a record's state or phone area code.
enum CallZone: String, Codable, CaseIterable, Identifiable, Sendable {
    case atlantic, eastern, central, mountain, pacific, alaska, hawaii

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// East = 0 ... Hawaii = 6, for East -> West ordering.
    var eastRank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var timeZone: TimeZone {
        let name: String
        switch self {
        case .atlantic: name = "America/Halifax"
        case .eastern: name = "America/New_York"
        case .central: name = "America/Chicago"
        case .mountain: name = "America/Denver"
        case .pacific: name = "America/Los_Angeles"
        case .alaska: name = "America/Anchorage"
        case .hawaii: name = "Pacific/Honolulu"
        }
        return TimeZone(identifier: name) ?? .current
    }

    /// The hour (0-23) it is in this zone right now.
    func hour(at date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.component(.hour, from: date)
    }

    func timeString(at date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// State first (where they are), then phone area codes.
    static func of(state: String?, phones: [String?]) -> CallZone? {
        if let code = stateCode(state), let z = stateZones[code] { return z }
        for p in phones { if let a = areaCode(p), let z = zone(areaCode: a) { return z } }
        return nil
    }

    static func stateCode(_ state: String?) -> String? {
        let s = (state ?? "").replacingOccurrences(of: ".", with: "").trimmed
        if s.count == 2 { return s.uppercased() }
        return stateNames[s.lowercased()]
    }

    static func areaCode(_ phone: String?) -> String? {
        guard let phone = phone?.trimmed, !phone.isEmpty else { return nil }
        if phone.hasPrefix("+"), !phone.hasPrefix("+1") { return nil }
        var digits = phone.filter(\.isNumber)
        if digits.count >= 11, digits.hasPrefix("1") { digits.removeFirst() }
        guard digits.count >= 10 else { return nil }
        return String(digits.prefix(3))
    }

    static func zone(areaCode code: String) -> CallZone? {
        if let special = areaCodeOverrides[code] { return special }
        return areaCodeStates[code].flatMap { stateZones[$0] }
    }

    /// Each state's time zone (the one most of its people live in, for states with two).
    static let stateZones: [String: CallZone] = {
        var out: [String: CallZone] = [:]
        let groups: [(CallZone, String)] = [
            (.atlantic, "NB NS PE NL"),
            (.eastern, "CT DE DC FL GA IN KY ME MD MA MI NH NJ NY NC OH PA RI SC VT VA WV ON QC NU"),
            (.central, "AL AR IL IA KS LA MN MS MO NE ND OK SD TN TX WI MB SK"),
            (.mountain, "AZ CO ID MT NM UT WY AB YT NT"),
            (.pacific, "CA NV OR WA BC"),
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
        // Canada
        "british columbia": "BC", "alberta": "AB", "saskatchewan": "SK", "manitoba": "MB", "ontario": "ON",
        "quebec": "QC", "québec": "QC", "new brunswick": "NB", "nova scotia": "NS", "prince edward island": "PE",
        "newfoundland and labrador": "NL", "newfoundland": "NL", "yukon": "YT", "northwest territories": "NT",
        "nunavut": "NU",
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
            // Canada
            "BC": "236 250 257 604 672 778",
            "AB": "368 403 587 780 825",
            "SK": "306 474 639",
            "MB": "204 431 584",
            "ON": "226 249 289 343 365 382 416 437 519 548 613 647 683 705 742 753 807 905",
            "QC": "263 354 367 418 438 450 468 514 579 581 819 873",
            "NB": "428 506",
            "NS": "782 902",
            "NL": "709",
            "YT": "867",
        ]
        var out: [String: String] = [:]
        for (state, codes) in byState {
            for code in codes.split(separator: " ") { out[String(code)] = state }
        }
        return out
    }()
}

