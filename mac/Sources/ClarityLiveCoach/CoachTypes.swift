import Foundation

// MARK: - What Claude sends back

struct Suggestion: Equatable {
    var say = ""
    var cue = ""
    var stage = ""
    var skip = false
    /// True once the SAY line is fully written (a line break came after it, or the answer ended).
    var sayComplete = false
    /// Codes of the meeting times this line offers or confirms, e.g. ["T3", "T5"].
    var offered: [String] = []
    /// Voicemail follow-ups: a text to send and a LinkedIn connection note.
    var textMessage = ""
    var linkedin = ""
    var linkedinMessage = ""
    /// Phone tree: the keys to press now (0-9, * and #), for the one-click button.
    var keys = ""

    /// Claude answers in a tiny line format so words can show while they stream:
    ///   SAY: ...
    ///   CUE: ...
    ///   STAGE: ...
    ///   OFFERED: T3, T5   (only when the line offers meeting times)
    /// or SKIP when the rep needs no help.
    static func parse(_ text: String) -> Suggestion {
        var s = Suggestion()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SAY:") {
                s.say = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if !s.say.isEmpty { s.sayComplete = true } // any line after SAY means SAY is done
            if trimmed.hasPrefix("CUE:") { s.cue = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("STAGE:") { s.stage = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("SKIP") { s.skip = true }
            else if trimmed.hasPrefix("TEXT:") { s.textMessage = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("KEYS:") {
                s.keys = String(trimmed.dropFirst(5).filter { "0123456789*#".contains($0) }.prefix(12))
            }
            else if trimmed.hasPrefix("LINKEDIN MESSAGE:") { s.linkedinMessage = String(trimmed.dropFirst(17)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("LINKEDIN:") { s.linkedin = String(trimmed.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
            else if trimmed.hasPrefix("OFFERED:") {
                s.offered = trimmed.dropFirst(8).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            }
        }
        return s
    }
}

// MARK: - Voicemail follow-ups

struct FollowUp: Equatable {
    /// Which record this is for, so a 2nd-try voicemail keeps what the 1st try already sent.
    var key: String?
    var prospect: String?
    var text = ""
    /// The rep typed in the text box: never overwrite their words with a fresh draft.
    var textEdited = false
    var linkedin = ""
    var textDone = false
    var linkedinDone = false
    /// Their phone, from the Salesforce page; editable on the card.
    var phone = ""
    /// Their LinkedIn profile, from the Salesforce record's LinkedIn field.
    var linkedinURL: URL?
    /// A note for the text row ("Sending...", an error). nil once sent.
    var textStatus: String?
    /// The text is on its way: the Send button waits.
    var sending = false
    /// A LinkedIn direct message, for people who are already connected.
    var linkedinMessage = ""
    var linkedinMessageDone = false
    /// What the 21-day plan says to send today.
    var textDue = false
    var linkedInDue = false
    var linkedInMessageFirst = false // the last call day: a message, not a connection note

    /// Everything due today is done.
    /// Connect day: both the note and the message. Last call day: the message.
    var allDone: Bool {
        (textDone || !textDue)
            && (!linkedInDue || (linkedInMessageFirst ? linkedinMessageDone : linkedinDone && linkedinMessageDone))
    }
}

// MARK: - The person on screen

/// Everything the coach knows about the person on screen. Async work (page text, voicemail,
/// opener) checks it's still for them before writing here.
struct Prospect: Equatable {
    /// From the Salesforce tab title, e.g. Lead "Jane Doe".
    var calling: String?
    /// Text from their Salesforce page, when Chrome allows it.
    var details: String?
    /// Their page was read (or tried).
    var detailsTried = false
    /// Their page is still loading: read it once it shows.
    var detailsPending = false
    /// Who Claude's personal opener on screen is for.
    var personalOpenerFor: String?
    /// Their voicemail, written ahead of time, and who it was written for.
    var voicemail: Suggestion?
    var voicemailFor: String?
    /// The record Id the voicemail is for (matches the follow-up card's key).
    var voicemailKey: String?
    /// The voicemail was written from their Salesforce page.
    var voicemailUsedDetails = false
}

// MARK: - Call state

enum Speaker { case rep, prospect }

struct Turn: Identifiable, Equatable {
    let id = UUID()
    let speaker: Speaker
    var text: String
}

/// Short noises that never need a new line on their own.
private let filler: Set<String> = [
    "yeah", "yep", "yes", "ok", "okay", "uh", "um", "uh-huh", "mhm", "mm-hmm", "hmm",
    "right", "sure", "got", "it", "cool", "nice", "great", "hello", "hi",
]

/// Lowercase words only, so "Sure, go ahead." matches "sure go ahead".
func normalized(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func isMeaningful(_ text: String) -> Bool {
    text.lowercased()
        .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
        .contains { !$0.isEmpty && !filler.contains($0) }
}

/// Holds the two transcription streams so audio threads can reach them safely.
final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rep: DeepgramStream?
    private var prospect: DeepgramStream?

    func set(rep: DeepgramStream?, prospect: DeepgramStream?) {
        lock.withLockValue { self.rep = rep; self.prospect = prospect }
    }

    func replace(_ speaker: Speaker, with stream: DeepgramStream?) {
        let old = lock.withLockValue { () -> DeepgramStream? in
            defer { if speaker == .rep { rep = stream } else { prospect = stream } }
            return speaker == .rep ? rep : prospect
        }
        old?.close()
    }

    func send(_ data: Data, isRep: Bool) {
        let stream = lock.withLockValue { isRep ? rep : prospect }
        stream?.send(data)
    }

    func closeAll() {
        let (r, p) = lock.withLockValue { (rep, prospect) }
        r?.close()
        p?.close()
        set(rep: nil, prospect: nil)
    }
}

// MARK: - The coach

/// What's been said on this call, plus the words still coming in. Changes many times a second.
@MainActor
final class LiveTranscript: ObservableObject {
    @Published var turns: [Turn] = []
    @Published var interim: [Speaker: String] = [:]
}
