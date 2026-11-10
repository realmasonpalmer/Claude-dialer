import Foundation

/// The Growth Stack Lunch: a lunch for Portland business leaders.
/// Leads in Portland or SW Washington get a lunch invite as their LinkedIn note, LinkedIn
/// message and first text, in place of the usual "I just tried calling" notes.
enum LocalLunch {
    static let link = "https://www.meetup.com/the-growth-stack-lunch/"

    /// LinkedIn connection note. Sent from the rep's own profile, so no name needed.
    static func linkedinNote(first: String) -> String {
        "Hey \(first), inviting you to a lunch for Portland business leaders. A lot of us are figuring out AI on our own, and I think we'd get further comparing notes. No pitches, just what's working and what isn't. Open to connecting? \(link)"
    }

    /// LinkedIn message, for people already connected.
    static func linkedinMessage(first: String) -> String {
        "Hey \(first), inviting you to a lunch for Portland business leaders. A lot of us are figuring out AI on our own, and I think we'd get further comparing notes. No pitches, just what's working and what isn't. Want to join us? \(link)"
    }

    /// First text. A text has no profile photo, so the rep says who they are.
    static func text(first: String, rep: String, company: String) -> String {
        "Hey \(first), it's \(rep) with \(company). Inviting you to a lunch for Portland business leaders. A lot of us are figuring out AI on our own, and comparing notes helps. No pitches. Want to join us? \(link)"
    }

    /// For Claude: how later texts and notes should sound for a local lead.
    static let promptNote = """
    This person is in the Portland / SW Washington area. Every TEXT, LINKEDIN and LINKEDIN MESSAGE line is an
    invite to the Growth Stack Lunch, not a "I just tried calling" note. Match this example's voice and length:
    "Hey Eric, inviting you to a lunch for Portland business leaders. A lot of us are figuring out AI on our own,
    and I think we'd get further comparing notes. No pitches, just what's working and what isn't. Open to connecting?
    \(link)"
    Warm, plain, peer to peer. No pitch, no product, no meeting ask. End with the link. A later text can be a
    short, light nudge about the same lunch in new words. This beats the campaign's text and LinkedIn templates.

    """

    // MARK: Who counts as local

    /// Portland metro, Oregon side.
    static let oregonCities: Set<String> = [
        "portland", "beaverton", "hillsboro", "gresham", "lake oswego", "tigard", "tualatin", "west linn",
        "oregon city", "milwaukie", "happy valley", "clackamas", "wilsonville", "sherwood", "forest grove",
        "troutdale", "fairview", "wood village", "gladstone", "cornelius", "king city", "durham", "sandy",
        "canby", "estacada", "scappoose", "st. helens", "st helens", "boring", "damascus", "north plains",
        "banks", "aloha", "cedar mill", "bethany", "oak grove", "jennings lodge",
    ]

    /// SW Washington: Clark, Cowlitz, Skamania and nearby.
    static let washingtonCities: Set<String> = [
        "vancouver", "camas", "washougal", "battle ground", "ridgefield", "la center", "yacolt", "amboy",
        "brush prairie", "hockinson", "orchards", "salmon creek", "hazel dell", "felida", "longview", "kelso",
        "kalama", "woodland", "castle rock", "stevenson", "north bonneville", "carson", "white salmon",
        "bingen", "cathlamet", "goldendale",
    ]

    /// True when the city and state put them in Portland or SW Washington.
    /// With no city, a 503 or 971 phone number (Portland's area codes) counts.
    static func isLocal(city: String?, state: String?, phones: [String?]) -> Bool {
        let c = clean(city)
        let s = clean(state)
        let oregon = s == "or" || s == "oregon"
        let washington = s == "wa" || s == "washington"
        if !c.isEmpty {
            if oregonCities.contains(c) { return oregon || s.isEmpty }
            if washingtonCities.contains(c) { return washington || s.isEmpty }
            if !s.isEmpty { return false } // a known city somewhere else
        }
        // No city: only Oregon or an unknown state can still count, by phone.
        guard s.isEmpty || oregon else { return false }
        return phones.contains { p in
            var d = (p ?? "").filter(\.isNumber)
            if d.count == 11, d.hasPrefix("1") { d.removeFirst() }
            return d.count == 10 && ["503", "971"].contains(String(d.prefix(3)))
        }
    }

    /// Chrome mode: read "Portland, OR" or "Vancouver, WA 98660" style addresses from the page text.
    static func isLocal(pageText: String?) -> Bool {
        guard let text = pageText?.lowercased() else { return false }
        func near(_ cities: Set<String>, _ states: [String]) -> Bool {
            cities.contains { city in
                states.contains { st in
                    text.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: city)),\s*\#(st)\b"#,
                               options: .regularExpression) != nil
                }
            }
        }
        return near(oregonCities, ["or", "oregon"]) || near(washingtonCities, ["wa", "washington"])
    }

    private static func clean(_ s: String?) -> String {
        (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
