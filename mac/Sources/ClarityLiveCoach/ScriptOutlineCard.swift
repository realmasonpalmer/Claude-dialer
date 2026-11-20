import SwiftUI

/// A fold-out card that just shows the campaign script. The part you're on is bold and highlighted.
struct ScriptOutlineCard: View {
    @ObservedObject var coach: CoachModel
    /// The one page version of the script (redraws when Claude finishes writing it).
    @ObservedObject private var pages = ScriptPage.shared
    @AppStorage(PrefKey.scriptOutlineOpen) private var open = false
    /// The "View Full Script" sheet: every part, no fold.
    var fullOnly = false

    struct Part: Identifiable {
        let id: String
        let title: String
        let text: String
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
                    return Part(id: Self.stageID(for: section.title), title: section.title, text: lines.joined(separator: "\n"))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !fullOnly {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("My script").font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }
            if open || fullOnly {
                ForEach(parts) { part in
                    let here = part.id == currentID
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(here ? Brand.text : Brand.muted)
                        Text(part.text.trimmed)
                            .font(.callout.weight(here ? .bold : .regular))
                            .foregroundStyle(here ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(here ? Brand.blue.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                if parts.isEmpty {
                    Text("No script yet. Next to SCRIPT at the top, click Edit Script, or pick Write a new script with Claude.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
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
