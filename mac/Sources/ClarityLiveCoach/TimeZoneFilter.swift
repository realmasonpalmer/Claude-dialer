import Foundation

/// The US and Canadian time zones a rep can call into, east to west.
enum CallZone: String, CaseIterable, Identifiable {
    case atlantic, eastern, central, mountain, pacific, alaska, hawaii

    var id: String { rawValue }

    var label: String {
        switch self {
        case .atlantic: return "Atlantic"
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

    /// The time there right now, like "2:15 PM".
    var timeNow: String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return Date().formatted(style)
    }

    // MARK: Working out someone's time zone

    /// The time zone from what's on the Salesforce record, most exact first:
    /// 1. City and state together (finds the other side of a two-zone state, like Pensacola, FL).
    /// 2. State or province.
    /// 3. City alone, when that city name is only in one time zone (Portland, OR and ME: skipped).
    /// 4. The phone's area code.
    /// nil = the record doesn't say, or it's outside the US and Canada.
    static func of(city: String? = nil, state: String?, country: String?, phones: [String?]) -> CallZone? {
        let c = clean(country)
        if !c.isEmpty, !usNames.contains(c), !canadaNames.contains(c) { return nil }
        let codes = phones.compactMap(areaCode)
        if let st = stateCode(state) {
            if let z = zone(city: city, state: st) { return z }
            // A few states have two time zones. A number from the same state says which side.
            if let code = codes.first(where: { areaCodeStates[$0] == st }) { return zone(areaCode: code) }
            return stateZones[st]
        }
        if let z = zone(city: city, state: nil) { return z }
        return codes.lazy.compactMap(zone(areaCode:)).first
    }

    /// The time zone of a city, from the city list. With a state: only that state's city.
    /// Without: only when every city by that name is in the same time zone.
    static func zone(city: String?, state: String?) -> CallZone? {
        // "Saint Louis" and "St Louis" are listed as "st. louis".
        var name = clean(city)
        if name.hasPrefix("saint ") { name = "st. " + name.dropFirst(6) }
        else if name.hasPrefix("st ") { name = "st. " + name.dropFirst(3) }
        guard !name.isEmpty, let places = cityZones[name] else { return nil }
        if let state { return places.first { $0.state == state }?.zone }
        let zones = Set(places.map { $0.zone })
        return zones.count == 1 ? zones.first : nil
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
    /// In a Country field, "CA" means Canada.
    private static let canadaNames: Set<String> = ["canada", "ca", "can"]

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

    /// City -> the states it's in, with the time zone there. A third part overrides the state's zone
    /// (cities on the other side of a two-zone state). Cities named in more than one zone are listed
    /// in each, so a city alone only counts when they agree. Portland metro and SW Washington come from LocalLunch.
    static let cityZones: [String: [(state: String, zone: CallZone)]] = {
        var out: [String: [(state: String, zone: CallZone)]] = [:]
        func add(_ city: String, _ state: String, _ zone: CallZone?) {
            guard let z = zone ?? stateZones[state] else { return }
            out[city, default: []].append((state, z))
        }
        for line in cityList.split(separator: "\n") {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            let state = parts[1]
            for city in parts[0].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !city.isEmpty {
                add(city, state, parts.count > 2 ? CallZone(rawValue: parts[2]) : nil)
            }
        }
        for city in LocalLunch.oregonCities { add(city, "OR", nil) }
        for city in LocalLunch.washingtonCities { add(city, "WA", nil) }
        return out
    }()

    private static let cityList = """
    birmingham, montgomery, huntsville, mobile, tuscaloosa, decatur, troy | AL
    anchorage, fairbanks, juneau | AK
    phoenix, tucson, mesa, chandler, scottsdale, gilbert, glendale, tempe, peoria, surprise, flagstaff | AZ
    little rock, fayetteville, fort smith, bentonville, rogers, springdale, jonesboro | AR
    los angeles, san diego, san jose, san francisco, fresno, sacramento, long beach, oakland, bakersfield, anaheim, santa ana, riverside, stockton, irvine, chula vista, fremont, san bernardino, modesto, oxnard, huntington beach, glendale, santa clarita, oceanside, rancho cucamonga, santa rosa, elk grove, corona, lancaster, palmdale, salinas, pomona, hayward, escondido, sunnyvale, torrance, pasadena, fullerton, thousand oaks, visalia, simi valley, concord, roseville, santa clara, vallejo, berkeley, palo alto, mountain view, menlo park, redwood city, san mateo, cupertino, santa monica, burbank, newport beach, costa mesa, walnut creek, pleasanton, san ramon, carlsbad, temecula, santa barbara, beverly hills, culver city, el segundo, lakewood, westminster, richmond, carmel, dublin, lake forest, brentwood, lincoln | CA
    denver, colorado springs, aurora, fort collins, lakewood, boulder, thornton, arvada, westminster, pueblo, greeley, longmont, englewood, littleton, broomfield, centennial, golden | CO
    hartford, new haven, stamford, bridgeport, norwalk, greenwich, waterbury, danbury, manchester | CT
    wilmington, dover, newark | DE
    washington, washington dc, washington d.c. | DC
    jacksonville, miami, tampa, orlando, st. petersburg, hialeah, tallahassee, fort lauderdale, port st. lucie, cape coral, pembroke pines, gainesville, coral springs, clearwater, boca raton, west palm beach, sarasota, naples, fort myers, boynton beach, delray beach, jupiter, coral gables, doral, kissimmee, lakeland, ocala, daytona beach, melbourne | FL
    pensacola, panama city, destin, fort walton beach | FL | central
    atlanta, augusta, columbus, savannah, athens, macon, alpharetta, marietta, roswell, sandy springs, duluth, kennesaw, norcross, peachtree city, gainesville, decatur | GA
    honolulu | HI
    boise, meridian, nampa, idaho falls, pocatello | ID
    coeur d'alene, lewiston | ID | pacific
    chicago, aurora, naperville, joliet, rockford, springfield, elgin, peoria, champaign, evanston, schaumburg, oak brook, bloomington, decatur, arlington heights, skokie, deerfield, lake forest, downers grove, itasca, rosemont, quincy, o'fallon | IL
    indianapolis, fort wayne, south bend, carmel, fishers, bloomington, lafayette, west lafayette, noblesville, zionsville | IN
    evansville, gary, hammond | IN | central
    des moines, cedar rapids, davenport, sioux city, iowa city, west des moines, ames, dubuque, waterloo | IA
    wichita, overland park, kansas city, olathe, topeka, lawrence, lenexa, leawood, manhattan | KS
    louisville, lexington, covington, frankfort | KY
    bowling green, owensboro, paducah | KY | central
    new orleans, baton rouge, shreveport, lafayette, lake charles, metairie, monroe, hammond | LA
    portland, bangor, augusta, lewiston | ME
    baltimore, columbia, rockville, bethesda, silver spring, annapolis, frederick, gaithersburg, towson | MD
    boston, worcester, springfield, cambridge, lowell, brockton, quincy, newton, waltham, burlington, framingham, woburn, lexington, needham, wellesley, andover, salem, plymouth, franklin | MA
    detroit, grand rapids, warren, sterling heights, ann arbor, lansing, flint, dearborn, troy, southfield, kalamazoo, novi, farmington hills, livonia, auburn hills, traverse city, birmingham, monroe, jackson | MI
    minneapolis, st. paul, rochester, duluth, bloomington, plymouth, eden prairie, minnetonka, edina, maple grove, eagan, st. cloud | MN
    jackson, gulfport, hattiesburg, biloxi, tupelo, southaven, meridian | MS
    kansas city, st. louis, springfield, columbia, independence, lee's summit, o'fallon, st. charles, chesterfield, clayton | MO
    billings, missoula, bozeman, great falls, helena | MT
    omaha, lincoln, bellevue, grand island, kearney | NE
    las vegas, henderson, reno, north las vegas, sparks, carson city | NV
    manchester, nashua, concord, portsmouth, dover | NH
    newark, jersey city, paterson, elizabeth, trenton, princeton, edison, hoboken, morristown, parsippany, iselin, woodbridge, cherry hill, camden, new brunswick, red bank, short hills, montclair, wayne | NJ
    albuquerque, las cruces, santa fe, rio rancho, roswell | NM
    new york, new york city, nyc, brooklyn, queens, bronx, staten island, manhattan, buffalo, rochester, yonkers, syracuse, albany, white plains, long island city, ithaca, schenectady, utica, binghamton, garden city, melville, hauppauge, tarrytown, rye, purchase, armonk, troy | NY
    charlotte, raleigh, greensboro, durham, winston-salem, fayetteville, cary, wilmington, high point, asheville, chapel hill, morrisville, concord, greenville, burlington | NC
    fargo, bismarck, grand forks, minot | ND
    columbus, cleveland, cincinnati, toledo, akron, dayton, canton, youngstown, dublin, mason, westerville, beachwood, independence, bowling green, hamilton, athens | OH
    oklahoma city, tulsa, norman, broken arrow, edmond, lawton | OK
    portland, salem, eugene, bend, medford, corvallis | OR
    philadelphia, pittsburgh, allentown, erie, reading, scranton, lancaster, harrisburg, bethlehem, king of prussia, malvern, wayne, conshohocken, radnor, blue bell, state college, york, west chester | PA
    providence, warwick, cranston, newport | RI
    columbia, charleston, greenville, north charleston, mount pleasant, rock hill, myrtle beach, spartanburg | SC
    sioux falls, aberdeen | SD
    rapid city | SD | mountain
    nashville, memphis, clarksville, murfreesboro, franklin, brentwood, jackson | TN
    knoxville, chattanooga, johnson city, kingsport | TN | eastern
    houston, san antonio, dallas, austin, fort worth, arlington, corpus christi, plano, laredo, lubbock, irving, garland, frisco, mckinney, amarillo, grand prairie, brownsville, killeen, denton, midland, waco, round rock, the woodlands, sugar land, richardson, addison, southlake, katy, spring, allen, carrollton, lewisville, pasadena, greenville, victoria, athens | TX
    el paso | TX | mountain
    salt lake city, west valley city, provo, west jordan, orem, sandy, ogden, st. george, lehi, draper, park city | UT
    burlington, montpelier | VT
    virginia beach, norfolk, chesapeake, richmond, newport news, alexandria, hampton, roanoke, arlington, mclean, reston, tysons, herndon, fairfax, vienna, charlottesville, lynchburg, leesburg, portsmouth | VA
    seattle, spokane, tacoma, bellevue, kent, everett, renton, redmond, kirkland, olympia, bellingham, yakima, federal way, bothell, issaquah, woodinville | WA
    charleston, huntington, morgantown | WV
    milwaukee, madison, green bay, kenosha, racine, appleton, waukesha, eau claire, oshkosh, brookfield | WI
    cheyenne, casper, laramie, jackson | WY
    vancouver, victoria, surrey, burnaby, richmond, kelowna | BC
    calgary, edmonton | AB
    saskatoon, regina | SK
    winnipeg | MB
    toronto, ottawa, mississauga, brampton, hamilton, london, markham, vaughan, kitchener, waterloo, oakville, burlington | ON
    montreal, montréal, quebec city, québec, laval, gatineau | QC
    halifax | NS
    moncton, fredericton | NB
    charlottetown | PE
    st. john's | NL
    whitehorse | YT
    yellowknife | NT
    iqaluit | NU
    """

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
        let city = text("City", "MailingCity") ?? (account?["BillingCity"] as? String)
        let country = text("Country", "MailingCountry")
        let found = CallZone.of(city: city, state: state, country: country,
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
            ? "Id, MobilePhone, Phone, City, State, Country"
            : "Id, MobilePhone, Phone, MailingCity, MailingState, MailingCountry, Account.BillingCity, Account.BillingState"
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
