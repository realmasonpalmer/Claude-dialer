import SwiftUI

/// A fold-out card that just shows the campaign script. The part you're on is bold and highlighted.
struct ScriptOutlineCard: View {
    @ObservedObject var coach: CoachModel
    /// The one page version of the script (redraws when Claude finishes writing it).
    @ObservedObject private var pages = ScriptPage.shared
    @AppStorage(PrefKey.scriptOutlineOpen) private var open = false
    /// The "View Full Script" sheet: every part, no fold.
    var fullOnly = false
    /// The Live Coach card is folded: the opener shows highlighted at the top of this card instead.
    var openerOnTop = false
    /// Saves an edited script (the card can't reach the call list store itself).
    var onScriptChange: ((String) -> Void)? = nil
    /// The part being edited on the card, and its text.
    @State private var editingID: String?
    @State private var draft = ""

    struct Part: Identifiable {
        let id: String
        let title: String
        let text: String
        /// The lines as written in the one-page script (before names are filled in), for editing.
        var raw: [String] = []
    }

    var parts: [Part] {
        let c = coach.campaign
        var list: [Part] = [
            Part(id: "opening", title: "Opening", text: c.opening),
            Part(id: "discovery", title: "Discovery", text: c.discovery),
            Part(id: "value", title: "Value", text: c.offer),
            Part(id: "closing", title: "Closing", text: c.closing),
            Part(id: "objection", title: "Objections", text: c.objections),
            Part(id: "exit", title: "When to stop", text: c.exit),
        ]
        // A whole script was pasted or generated: show its one page version (spoken lines only,
        // opener first), never the raw file with the tool's rules in it.
        if !c.pastedScript.trimmed.isEmpty {
            _ = pages.version
            let sections = pages.sections(for: c.pastedScript)
            if !sections.isEmpty {
                // The person's real name and company go in the slots ([Name], [Firm]); no one loaded: "there".
                return sections.map { section in
                    let lines = section.lines.map { line -> String in
                        let filled = coach.fillTags(line, for: coach.calling)
                        return filled.hasPrefix("there, ") ? "Hi " + filled : filled
                    }
                    return Part(id: Self.stageID(for: section.title), title: section.title, text: lines.joined(separator: "\n"),
                                raw: section.lines)
                }
            }
            list = list.filter { !$0.text.trimmed.isEmpty }
            if list.isEmpty {
                let note = pages.isWriting(c.pastedScript)
                    ? "Making your one page script. It takes a few seconds."
                    : "Your one page script isn't ready yet. Check your keys in Set up, then open this again."
                return [Part(id: "script", title: "Your script", text: note)]
            }
            return list
        }
        return list.filter { !$0.text.trimmed.isEmpty }
    }

    /// Which call stage a section of the one page script belongs to (for the highlight).
    private static func stageID(for title: String) -> String {
        let t = title.uppercased()
        if t.contains("OPENER") || t.contains("GATEKEEPER") || t.contains("VOICEMAIL") { return t.contains("OPENER") ? "opening" : "other-" + t }
        if t.contains("QUESTION") { return "discovery" }
        if t.contains("WHY") { return "value" }
        if t.contains("ASK") || t.contains("CLOSE") { return t.contains("ASK") ? "closing" : "other-" + t }
        if t.contains("IF THEY SAY") { return "objection" }
        return "other-" + t
    }

    /// Which part the call is on right now.
    var currentID: String {
        if coach.status == .ready { return "opening" }
        let stage = coach.suggestion.stage.lowercased()
        let theySpoke = coach.turns.contains { $0.speaker == .prospect }
        if stage.contains("objection") { return "objection" }
        if stage.contains("goal") || stage.contains("clos") || stage.contains("ask") || stage.contains("book") { return "closing" }
        if stage.contains("discover") || stage.contains("question") { return "discovery" }
        if stage.contains("value") || stage.contains("reason") || stage.contains("why") || stage.contains("problem") { return "value" }
        if stage.contains("exit") { return "exit" }
        // Still on the opener, but they answered it: the next thing to say is why you're calling.
        if (stage.contains("opener") || stage.isEmpty), theySpoke, !coach.sawVoicemail, !coach.screenerActive { return "value" }
        return "opening"
    }

    /// The Edit menu in the header (switch, edit or write scripts). Supplied by the coach.
    var editMenu: AnyView? = nil
    /// Long scripts show the first few parts until Show more.
    @State private var showAll = false
    private static let firstParts = 4

    var body: some View {
        // The opener already shows big on the coach card, so the fold-out skips it (the full view keeps it).
        let all = fullOnly ? parts : parts.filter { $0.id != "opening" }
        let shown = (fullOnly || showAll) ? all : Array(all.prefix(Self.firstParts))
        VStack(alignment: .leading, spacing: 12) {
            if !fullOnly {
                HStack(spacing: 8) {
                    // Chevron + title: one click target that folds the card.
                    Button { open.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(CardStyle.chevron).foregroundStyle(Brand.subtext)
                            Image(systemName: "doc.text").font(CardStyle.icon).foregroundStyle(Brand.blue)
                            Text("My Script").font(CardStyle.title)
                        }
                        .foregroundStyle(Brand.text)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    // Edit: its own click target, never folds the card.
                    if let editMenu { editMenu }
                }
            }
            if openerOnTop, !fullOnly, let part = parts.first(where: { $0.id == "opening" }) {
                let line = coach.openerStyle.map { coach.fillTags($0.template, for: nil) } ?? part.text.trimmed
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("OPENER").font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
                        Text("EXACT").font(.caption2.weight(.bold)).foregroundStyle(Color.green)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color.green.opacity(0.6), lineWidth: 1))
                    }
                    Text(line).font(.body.weight(.bold)).foregroundStyle(Brand.text)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.blue.opacity(0.5), lineWidth: 1))
            }
            if open || fullOnly {
                ForEach(shown) { part in
                    if part.id == "opening" {
                        // The opener: said word for word, so it stands out.
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(part.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Brand.subtext)
                                Text("EXACT").font(.caption2.weight(.bold)).foregroundStyle(Color.green)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .overlay(Capsule().stroke(Color.green.opacity(0.6), lineWidth: 1))
                            }
                            editable(part) {
                                Text(part.text.trimmed).font(.body.weight(.bold)).foregroundStyle(Brand.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Brand.quiet, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(part.id == currentID ? Brand.blue : Color.clear, lineWidth: 1))
                    } else {
                        let here = part.id == currentID
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: Self.icon(for: part.id)).font(.title3)
                                .foregroundStyle(here ? Brand.blue : Brand.subtext).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(part.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(here ? Brand.text : Brand.subtext)
                                editable(part) {
                                    Text(part.text.trimmed).font(.callout.weight(here ? .semibold : .regular))
                                        .foregroundStyle(here ? Brand.text : Brand.subtext)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !fullOnly, all.count > Self.firstParts {
                    Button { showAll.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(showAll ? "Show less" : "Show more")
                            Image(systemName: showAll ? "chevron.up" : "chevron.down").font(.caption)
                        }
                        .font(.callout).foregroundStyle(Brand.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.controlEdge, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if all.isEmpty {
                    Text("No script yet. Click Edit, then Write a new script with Claude.").font(.caption).foregroundStyle(Brand.muted)
                }
            }
        }
        .padding(CardStyle.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: CardStyle.radius)
    }

    /// A part's text; click it to edit in place (only for a written script, between calls).
    @ViewBuilder private func editable<V: View>(_ part: Part, @ViewBuilder text: () -> V) -> some View {
        if editingID == part.id + part.title {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $draft)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 70)
                    .background(Brand.navy.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.blue, lineWidth: 1))
                HStack(spacing: 10) {
                    Button("Save") { save(part) }.buttonStyle(BrandPrimaryButton())
                    Button("Cancel") { editingID = nil }.buttonStyle(.brandLink)
                    Text("One line per row. The coach uses your wording.").font(.caption).foregroundStyle(Brand.muted)
                }
            }
        } else if canEdit(part) {
            text()
                .contentShape(Rectangle())
                .onTapGesture { draft = part.raw.joined(separator: "\n"); editingID = part.id + part.title }
                .help("Click to edit these lines")
        } else {
            text()
        }
    }

    private func canEdit(_ part: Part) -> Bool {
        onScriptChange != nil && !part.raw.isEmpty && coach.status == .ready
    }

    private func save(_ part: Part) {
        // Keep the blank lines made with Enter (as the page's blank mark); only the start and end are trimmed.
        var lines = draft.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { ScriptPage.isBlank($0) ? ScriptPage.blank : $0 }
        while let first = lines.first, ScriptPage.isBlank(first) { lines.removeFirst() }
        while let last = lines.last, ScriptPage.isBlank(last) { lines.removeLast() }
        editingID = nil
        guard !lines.isEmpty, lines != part.raw else { return }
        let updated = pages.edit(script: coach.campaign.pastedScript, title: part.title, oldLines: part.raw, newLines: lines)
        onScriptChange?(updated)
    }

    /// An icon for each kind of script part.
    private static func icon(for id: String) -> String {
        switch id {
        case "value": return "scope"
        case "discovery": return "questionmark.circle"
        case "closing": return "calendar"
        case "objection": return "bubble.left.and.exclamationmark.bubble.right"
        case "exit": return "hand.raised"
        default: return "text.alignleft"
        }
    }
}

/// The five steps of every call, for the guided script: Intro, Qualify, Pitch, Close, Confirm.
enum ScriptStep: Int, CaseIterable, Identifiable {
    case intro, qualify, pitch, close, confirm
    var id: Int { rawValue }
    var title: String { ["Intro", "Qualify", "Pitch", "Close", "Confirm"][rawValue] }

    /// Which step a script part belongs to.
    static func of(partID id: String, title: String) -> ScriptStep {
        switch id {
        case "opening": return .intro
        case "discovery": return .qualify
        case "value": return .pitch
        case "closing", "objection": return .close
        case "exit": return .confirm
        default:
            let t = title.uppercased()
            if t.contains("CONFIRM") || t.contains("AFTER") || t.contains("BOOKED") || t.contains("WRAP") { return .confirm }
            if t.contains("CLOSE") { return .close }
            return .intro // gatekeeper, voicemail and other openers
        }
    }
}

/// Inside the live coach card: where the call is (Intro to Confirm), Previous / Next to read any step
/// of the script, and View Full Script. Reading only: editing is the Edit Script button at the top.
struct ScriptStepper: View {
    @ObservedObject var coach: CoachModel
    @ObservedObject private var pages = ScriptPage.shared
    /// A step the rep is reading (nil = follow the call).
    @Binding var browsing: ScriptStep?
    @Binding var showFull: Bool

    var body: some View {
        let outline = ScriptOutlineCard(coach: coach)
        let parts = outline.parts
        let live = ScriptStep.of(partID: outline.currentID, title: "")
        let shown = browsing ?? live
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(ScriptStep.allCases) { step in
                    let on = step == shown
                    Button { browsing = step == live ? nil : step } label: {
                        Text(step.title)
                            .font(.caption.weight(on ? .bold : .medium))
                            .foregroundStyle(on ? Brand.text : Brand.muted)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? Brand.blue.opacity(0.35) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(step == live ? Brand.blue : Color.clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(step == live ? "The step the call is on" : "Read the \(step.title) part of your script")
                    if step != .confirm {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Brand.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            if let b = browsing {
                let text = parts.filter { ScriptStep.of(partID: $0.id, title: $0.title) == b }
                    .map { $0.text.trimmed }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                Text(text.isEmpty ? "Your script has nothing for \(b.title)." : text)
                    .font(.callout).foregroundStyle(Brand.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.navy.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                Button { move(-1, from: shown, live: live) } label: { Label("Previous", systemImage: "chevron.left") }
                    .buttonStyle(.brandLink).font(.caption)
                    .disabled(shown == .intro)
                Button { move(1, from: shown, live: live) } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(.brandLink).font(.caption)
                    .disabled(shown == .confirm)
                if browsing != nil {
                    Button("Back to the call") { browsing = nil }.buttonStyle(.brandLink).font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
                Button("View Full Script") { showFull = true }.buttonStyle(.brandLink).font(.caption)
            }
        }
        .onChange(of: coach.status) { browsing = nil }
    }

    private func move(_ by: Int, from: ScriptStep, live: ScriptStep) {
        guard let next = ScriptStep(rawValue: from.rawValue + by) else { return }
        browsing = next == live ? nil : next
    }
}
