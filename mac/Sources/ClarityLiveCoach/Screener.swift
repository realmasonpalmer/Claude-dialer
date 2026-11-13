import Foundation

/// Spots automated call screeners (iPhone, Google Call Screen, carrier screening) and
/// "who's calling?" gatekeepers from the prospect's words, instantly and without Claude.
enum Screener {
    private static let phrases = [
        "screening service", "call screen", "screening this call", "being screened", "screening calls",
        "person you're trying to reach",
        "say your name", "state your name", "record your name", "speak your name",
        "your name and why", "your name and the reason", "reason for your call", "reason for calling",
        "why you're calling", "why you are calling", "what you're calling about", "what this call is about",
        "google assistant", "stay on the line", "before i connect you", "see if this person is available",
        "may i ask who's calling", "may i ask who is calling", "who's calling please", "who is calling please",
        "may i tell them who's calling", "and your name",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "’", with: "'")
        return phrases.contains { t.contains($0) }
    }

    /// "This is Mason calling for Jane."
    static func line(calling: String?) -> String {
        let rep = Prefs.repName
        return "This is \(rep.isEmpty ? "[your name]" : rep) calling for \(firstName(calling) ?? "[their name]")."
    }

    /// The full name from a record like: Lead "Jane Doe" -> Jane Doe. Any record type.
    static func fullName(_ calling: String?) -> String? {
        guard let calling, let open = calling.firstIndex(of: "\"") else { return nil }
        let rest = calling[calling.index(after: open)...]
        let inside = rest.lastIndex(of: "\"").map { rest[..<$0] } ?? rest
        let name = inside.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// First name from a record like: Lead "Jane Doe". People only, not companies.
    static func firstName(_ calling: String?) -> String? {
        guard let calling,
              ["Lead", "Contact", "Person Account"].contains(where: { calling.hasPrefix($0) }),
              let open = calling.firstIndex(of: "\""),
              let name = calling[calling.index(after: open)...].split(separator: " ").first else { return nil }
        let first = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // "Unknown" is a placeholder, not a name: callers fall back to "there".
        return first.isEmpty || Salesforce.isPlaceholderName(first) ? nil : first
    }
}

/// Spots voicemail greetings and full mailboxes from the prospect's words, instantly.
/// Strong phrases count any time. Early phrases ("you've reached", "not available") only count
/// at the start of a call before the rep has spoken, when it can't be a gatekeeper answering a question.
enum Voicemail {
    private static let strong = [
        "leave a message", "leave your message", "leave me a message", "leave a voicemail", "leave a brief message",
        "leave your name", "message after", "after the tone", "after the beep", "at the tone", "at the beep",
        "voicemail", "voice mail", "mailbox", "record your message", "please leave", "can't take your call",
        "cannot take your call", "can not take your call", "not available to take your call", "can't come to the phone",
        "cannot come to the phone", "get back to you as soon as", "return your call", "forwarded to an automated",
        "automated voice", "voice messaging", "is not available. please", "sorry i missed your call",
        "sorry i can't answer", "sorry i cannot answer", "missed your call",
        // Straight to voicemail and carrier recordings
        "record your message", "please record", "when you have finished recording", "when you're finished recording",
        "when you are finished recording", "finished recording", "press pound", "hang up or press", "for more options",
        "at the sound of the tone", "after the signal", "voice mailbox", "has a mailbox", "has been forwarded",
        "your call has been forwarded", "forwarded to voicemail", "is not accepting calls", "is not available to take",
        "this is the voicemail", "reached the voicemail", "reached the mailbox", "leave your number",
        "leave a detailed message", "leave your contact", "leave a short message", "leave a quick message",
        "i'll call you back", "i will call you back", "i'll get back to you", "i will get back to you",
        "call you back as soon", "get back to you shortly", "sorry i missed you", "sorry we missed your call",
        "can't take your call", "unable to take your call", "google subscriber", "the subscriber you",
        "the party you are trying", "the customer you are calling", "please try your call again",
        "please try again later", "send a numeric page", "to page this person",
    ]
    private static let early = [
        "you've reached", "you have reached", "not available", "unavailable", "unable to answer", "unable to take",
        "can't get to the phone", "can't answer", "away from my desk", "away from the phone", "out of the office",
        "subscriber", "wireless customer", "the person you are trying", "the person you're trying",
        "the number you have dialed", "is not reachable",
        "i'm not available right now", "i am not available right now", "not available right now",
    ]
    private static let fullPhrases = [
        "mailbox is full", "mailbox full", "cannot accept any messages", "not accepting messages",
        "has not been set up", "hasn't been set up", "not set up yet",
    ]

    /// - Parameter earlyInCall: true in the first seconds after pickup, before the rep has said anything.
    static func detects(_ text: String, earlyInCall: Bool) -> Bool {
        contains(text, strong) || mailboxFull(text) || (earlyInCall && contains(text, early))
    }

    static func mailboxFull(_ text: String) -> Bool { contains(text, fullPhrases) }

    /// Words only a recording says, never a person who picked up. Used to hang up a 1st-try
    /// voicemail by itself. Kept short on purpose: anything a live person might say is left out.
    private static let certainPhrases = [
        "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
        "after the signal", "record your message", "please record", "when you have finished recording",
        "when you're finished recording", "when you are finished recording", "voice mailbox", "forwarded to voicemail", "forwarded to an automated",
        "your call has been forwarded", "reached the voicemail", "this is the voicemail", "reached the mailbox",
        "google subscriber", "the subscriber you", "the party you are trying", "the customer you are calling",
        "send a numeric page", "to page this person",
    ]

    /// The beep is coming: only a mailbox says these (a phone menu doesn't).
    private static let recordingPhrases = [
        "after the tone", "after the beep", "at the tone", "at the beep", "at the sound of the tone",
        "after the signal", "record your message", "please record", "finished recording",
    ]
    static func recordingPrompt(_ text: String) -> Bool { contains(text, recordingPhrases) }

    /// True only when it's surely a recording (see `certainPhrases`), or the mailbox is full.
    static func certain(_ text: String) -> Bool {
        contains(text, certainPhrases) || mailboxFull(text) || numberCantTakeCall(text)
    }

    /// The carrier's "The telephone number 205 441 3049 can't take your call now." Fuzzy: a number
    /// (digits are dropped, so spoken or written both work), then within a few words "can't take your call".
    static func numberCantTakeCall(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(zero|oh|one|two|three|four|five|six|seven|eight|nine)\b"#, with: " ", options: .regularExpression)
        let pattern = #"\b(telephone|phone|number|caller|subscriber)\b(\s+\w+){0,6}?\s+"#
            + #"(cant|can not|cannot|unable to|isnt able to|is not able to|not able to)\s+(take|answer|accept)\s+(your|the|this)?\s*call"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Sure enough it's a recording to hang up now, without waiting for "after the beep" at the end
    /// of the greeting. Returns why (for the log), or nil. The rep hasn't spoken yet (caller checks).
    /// - Any time: words only a machine says (`certain`).
    /// - Early in the call, nobody screening: a voicemail phrase ("you've reached Jane's voicemail",
    ///   "can't take your call", "leave a message"), or 18+ words with no pause for a reply,
    ///   or "you've reached" / "not available" plus 12+ words.
    static func hangUpReason(_ recent: String, firstWords: String, earlyInCall: Bool) -> String? {
        if certain(recent) { return "beep words" }
        guard earlyInCall, !Screener.detects(firstWords), !Screener.detects(recent) else { return nil }
        if contains(recent, strong) { return "voicemail words" }
        if longGreeting(firstWords, earlyInCall: true) { return "long greeting" }
        if contains(recent, early), firstWords.split(separator: " ").count >= 12 { return "greeting words" }
        return nil
    }

    /// After a call screener (Google, iPhone): the screener says the person won't take it.
    /// Fuzzy, since the words vary and transcripts drop or mangle some:
    /// "I'm sorry, this person is not available", "the person you're calling isn't available right now",
    /// "sorry, they can't take your call", "this person's unavailable", "they declined".
    /// A person (or "they") followed within a few words by a "can't take it" phrase.
    static func unavailableAfterScreen(_ text: String) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z ]+"#, with: " ", options: .regularExpression)
        let pattern = #"\b(person|persons|party|they|theyre|user|customer|caller)\b(\s+\w+){0,6}?\s+"#
            + #"(not available|unavailable|isnt available|not able to (take|answer|come)|cant (take|answer|come|get)|"#
            + #"cannot (take|answer|come|get)|unable to (take|answer|come)|not taking calls|declined|busy right now)"#
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    /// Real people answer short ("Hello?", "This is Jane"). A recording talks on and on.
    /// 18+ words before the rep says anything, early in the call = a voicemail greeting.
    static func longGreeting(_ text: String, earlyInCall: Bool) -> Bool {
        earlyInCall && text.split(separator: " ").count >= 18
    }

    private static func contains(_ text: String, _ list: [String]) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return list.contains { t.contains($0) }
    }
}


/// Spots carrier messages for numbers that don't work, so the app skips them instead of
/// leaving a voicemail or offering a redial.
enum BadNumber {
    private static let phrases = [
        "not in service", "no longer in service", "is not in service", "been disconnected",
        "is disconnected", "not a working number", "is not working", "cannot be completed as dialed",
        "can not be completed as dialed", "could not be completed", "call cannot be completed",
        "check the number and dial again", "check the number and try again", "please check the number",
        "not a valid number", "invalid number", "number is invalid", "number you have dialed is not",
        "number you dialed is not", "has been changed", "temporarily out of service", "is not available for calls",
        "does not accept calls", "is restricted", "not accepting calls at this time",
        // "Can't receive calls" and other carrier refusals
        "cannot receive calls", "can't receive calls", "can not receive calls", "unable to receive calls",
        "not able to receive calls", "is not able to receive", "cannot accept calls", "can't accept calls",
        "is not accepting calls", "not accepting incoming calls", "calling restrictions", "has restricted",
        "has been restricted", "no longer available", "cannot be reached", "can't be reached",
        "is not reachable at this", "call cannot be completed at this time", "your call cannot be completed",
        "your call could not be completed", "not been completed", "has been suspended", "is suspended",
        "number has been disconnected", "is no longer a working", "not a valid phone number",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return phrases.contains { t.contains($0) }
    }
}


/// Spots an automated phone menu ("press 1 for sales", "dial by name"). The rep doesn't work
/// those: the app hangs up and takes the person off the list.
enum PhoneTree {
    /// One of these is enough: only a phone menu says them.
    private static let strong = [
        "menu options have changed", "listen carefully as our", "dial by name", "company directory",
        "your party's extension", "party's extension", "if you know the extension", "if you know your party",
        "para español", "para espanol", "main menu", "make a selection", "please select from the following",
        "say or press", "press or say", "to repeat these options", "for all other inquiries", "for all other calls",
    ]
    /// Two of these together, one of them "press ...": "press 1 for sales, press 2 for billing".
    private static let weak = [
        "press 1", "press one", "press 2", "press two", "press 3", "press three", "press 4", "press four",
        "press 9", "press nine", "press 0", "press zero", "for sales", "for billing", "for customer service",
        "for support", "for accounts", "to speak with an operator", "to speak to an operator", "operator",
        "extension", "our hours are", "business hours",
    ]

    static func detects(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if strong.contains(where: { t.contains($0) }) { return true }
        // Two menu phrases, and at least one is "press ..." (a live receptionist never says that).
        let hits = weak.filter { t.contains($0) }
        return hits.count >= 2 && hits.contains { $0.hasPrefix("press") }
    }
}
