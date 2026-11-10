import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Lines taken straight from the campaign script: opener, texts, LinkedIn notes, voicemails.
extension CoachModel {
    func instantOpener(for calling: String?) -> Suggestion {
        // Rotation off: the campaign script's own opener, never a built-in one.
        // (Claude's version, fitted to them, replaces it a moment later.)
        if openerStyle == nil {
            if let line = scriptOpenerLine() {
                return Suggestion(say: fillBlanks(fillTags(line, for: calling), for: calling),
                                  cue: "Your script's opener", stage: "Opener", sayComplete: true)
            }
            return Suggestion(say: "Reading your script's opener...", cue: "Your script's opener", stage: "Opener", sayComplete: false)
        }
        var t = openerStyle?.template ?? Opener.all[0].template
        if t.contains("[a ") { t = Opener.all[0].template } // needs Claude to fill in; use the plain one
        let rep = Prefs.repName
        t = t.replacingOccurrences(of: "[first name]", with: Screener.firstName(calling) ?? "there")
            .replacingOccurrences(of: "[rep]", with: rep.isEmpty ? "[your name]" : rep)
            .replacingOccurrences(of: "[company]", with: shortCompany)
            .replacingOccurrences(of: " [industry] teams", with: " teams") // Claude's version names their industry
        return Suggestion(say: t, cue: openerStyle?.name ?? "Opener", stage: "Opener", sayComplete: true)
    }

    /// The script's first line for when they pick up: what Claude found reading the whole script,
    /// else the first quoted line of the campaign's Opening. Raw (blanks and placeholders as written).
    func scriptOpenerLine() -> String? {
        let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
        if let line = found?.opener { return line }
        let opening = campaign.opening.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.isEmpty else { return nil }
        for (open, close) in [("\"", "\""), ("“", "”")] {
            if let a = opening.range(of: open), let b = opening.range(of: close, range: a.upperBound..<opening.endIndex) {
                return String(opening[a.upperBound..<b.lowerBound])
            }
        }
        return opening
    }

    /// "Is this ___?" → "Is this Adam?": a blank right after words that ask for the person.
    func fillBlanks(_ text: String, for calling: String?) -> String {
        guard let first = Screener.firstName(calling) else { return text }
        var t = text
        for lead in ["is this", "am i speaking with", "speaking with", "is that", "calling for", "looking for", "hi", "hey", "hello"] {
            t = t.replacingOccurrences(of: #"(?i)\b(\#(lead))\s+_{2,}"#, with: "$1 \(first)", options: .regularExpression)
        }
        return t
    }

    /// The script was just read by Claude: refresh the card's templates and the opener on screen.
    func scriptRead() {
        refillFromScript()
        if var v = voicemailScript, voicemailFor == calling {
            applyScriptVoicemail(&v, for: calling)
            voicemailScript = v
        }
        if status == .ready, openerStyle == nil { prepareOpener() }
    }

    /// Fills {first name}, {rep}, {company} and their [bracket] versions (any capitalization).
    func fillTags(_ text: String, for calling: String?) -> String {
        var t = text
        let rep = Prefs.repName
        let first = Screener.firstName(calling) ?? "there"
        let tags: [(names: [String], value: String)] = [
            (["first name", "firstname", "first", "name", "prospect", "prospect name"], first),
            (["rep", "rep name", "your name", "my name", "rep first name"], rep.isEmpty ? "[your name]" : rep),
            (["company", "your company", "rep company"], shortCompany),
        ]
        for (names, value) in tags {
            for n in names {
                for (o, c) in [("{", "}"), ("[", "]")] {
                    t = t.replacingOccurrences(of: o + n + c, with: value, options: .caseInsensitive)
                }
            }
        }
        return t
    }

    /// A message the campaign script spells out, found by its label (like "Missed call text:").
    /// The label must start the line (after any bullet). Takes the words after it on the same line, or the lines under it up to the next
    /// blank line or heading. Quotes around it are dropped. nil if the script has no such label.
    func scriptPiece(_ labels: [String]) -> String? {
        let lines = campaignText.components(separatedBy: "\n")
        for label in labels {
            for (i, line) in lines.enumerated() {
                // Only a label at the start of a line (after bullets, numbers or "#"), not the
                // same words in the middle of a sentence.
                let head = String(line.drop { " \t#*-•–0123456789.)".contains($0) })
                // Little words don't matter: "Text after a missed call" matches "text after missed call".
                guard Self.plain(head).hasPrefix(Self.plain(label)) else { continue }
                // "Label: message" or "Label - message" or "Label “message”" = the message is on this line.
                // Anything else after the label ("(under 200 characters)", "/connection request") is
                // part of the heading, and the message is on the lines under it.
                var rest = ""
                if let colon = head.firstIndex(of: ":") {
                    rest = String(head[head.index(after: colon)...])
                } else if let q = head.firstIndex(where: { "\"“".contains($0) }) {
                    rest = String(head[q...])
                } else if let dash = head.range(of: " - ") ?? head.range(of: " – ") ?? head.range(of: " — ") {
                    rest = String(head[dash.upperBound...])
                }
                var body = rest.trimmingCharacters(in: .whitespaces)
                if body.isEmpty {
                    var under: [String] = []
                    for next in lines[(i + 1)...] {
                        let t = next.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty { if under.isEmpty { continue } else { break } }
                        if t.hasPrefix("#") || (t.hasSuffix(":") && t.count < 40) { break }
                        // The next label starts: stop.
                        let next = t.drop { " \t#*-•–0123456789.)".contains($0) }.lowercased()
                        if ["linkedin", "missed call", "voicemail", "sms", "email", "text message", "follow-up", "follow up"]
                            .contains(where: { next.hasPrefix($0) }) { break }
                        under.append(t)
                    }
                    body = under.joined(separator: " ")
                }
                body = ScriptTemplates.cleanTemplate(body)
                if body.count >= 15 { return String(body.prefix(1000)) }
            }
        }
        return nil
    }

    /// Lowercase, no "a", "an" or "the", single spaces, straight apostrophes: for matching labels.
    static func plain(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .filter { !["a", "an", "the"].contains($0) }
            .joined(separator: " ")
    }

    /// The campaign's own missed call text and LinkedIn notes win over anything written for them.
    /// The script's text is used for the first text to this person; later texts are written fresh
    /// in the same voice. The LinkedIn note and message fall back to the missed call text.
    func applyScriptMessages(_ s: inout Suggestion, for calling: String?) {
        // Best: Claude read the whole script and found the templates (any headings, any layout).
        // Until that's done (a few seconds, once per script), a simple label match fills in.
        let found = ScriptTemplates.shared.templates(for: campaignText) { [weak self] in self?.scriptRead() }
            ?? labeledTemplates()
        // Text 1 is the missed call text, text 2 the next template, and so on. Past the last one, Claude writes them.
        let sent = recordKey().map { DialHistory.sentTexts($0).count } ?? 0
        if sent < found.texts.count { s.textMessage = fillTags(found.texts[sent], for: calling) }
        let text = found.texts.first
        if let n = found.linkedinNote ?? found.linkedinMessage ?? text { s.linkedin = fillTags(n, for: calling) }
        if let m = found.linkedinMessage ?? found.linkedinNote ?? text { s.linkedinMessage = fillTags(m, for: calling) }
        // Portland and SW Washington: the lunch invite beats the script's notes. Later texts are Claude's,
        // written as lighter nudges about the same lunch.
        if isLocalLead {
            let first = Screener.firstName(calling) ?? "there"
            let rep = Prefs.repName
            s.linkedin = LocalLunch.linkedinNote(first: first)
            s.linkedinMessage = LocalLunch.linkedinMessage(first: first)
            if sent == 0 { s.textMessage = LocalLunch.text(first: first, rep: rep.isEmpty ? "[your name]" : rep, company: shortCompany) }
        }
    }

    /// In Portland or SW Washington: from the lead's city and state, else the Salesforce page text,
    /// else a 503 or 971 phone number.
    var isLocalLead: Bool {
        if leads.isActive, let d = leads.details {
            return LocalLunch.isLocal(city: d.city, state: d.state, phones: [d.mobile, d.phone])
        }
        return LocalLunch.isLocal(pageText: recordDetails)
            || LocalLunch.isLocal(city: nil, state: nil, phones: [followUp?.phone, Aircall.phone(in: recordDetails)])
    }

    /// The campaign script's voicemail, word for word with the blanks filled, in place of a written one.
    /// 1st voicemail to this person = the script's 1st, and so on. Past the last, Claude's version stays.
    func applyScriptVoicemail(_ s: inout Suggestion, for calling: String?) {
        guard let found = ScriptTemplates.shared.templates(for: campaignText, onReady: { [weak self] in self?.scriptRead() }),
              !found.voicemails.isEmpty else { return }
        let left = recordKey().map { DialHistory.person($0).voicemails.count } ?? 0
        guard left < found.voicemails.count else { return }
        s.say = fillBlanks(fillTags(found.voicemails[left], for: calling), for: calling)
        s.cue = "Your script's voicemail. Wait for the beep."
    }

    /// The script was just read: put its templates on the open card (anything not sent yet).
    func refillFromScript() {
        guard var f = followUp else { return }
        var s = Suggestion()
        applyScriptMessages(&s, for: calling)
        if !f.textDone, !f.textEdited, !s.textMessage.isEmpty { f.text = s.textMessage }
        if !f.linkedinDone, !s.linkedin.isEmpty { f.linkedin = s.linkedin }
        if !f.linkedinMessageDone, !s.linkedinMessage.isEmpty { f.linkedinMessage = s.linkedinMessage }
        followUp = f
    }

    /// The quick fallback: templates found by their headings.
    func labeledTemplates() -> ScriptTemplates.Found {
        let text = scriptPiece(["missed call text", "missed-call text", "missed call sms", "missed call message",
                                "text after missed call", "text after voicemail", "text after call", "voicemail text",
                                "text message", "sms", "missed call"])
        let second = scriptPiece(["if no reply", "if they don't reply", "if no response", "no reply", "second text",
                                  "2nd text", "text 2", "follow-up text", "follow up text"])
        let note = scriptPiece(["linkedin connection message", "linkedin connection request", "linkedin connection note",
                                "linkedin connect message", "linkedin connect", "linkedin connection",
                                "connection request", "linkedin note", "linkedin request", "connect note"])
        let message = scriptPiece(["linkedin message", "linkedin dm", "linkedin direct message", "linkedin follow"])
        let texts = text.map { [$0] + (second.map { [$0] } ?? []) } ?? []
        return ScriptTemplates.Found(texts: texts, linkedinNote: note, linkedinMessage: message)
    }
}
