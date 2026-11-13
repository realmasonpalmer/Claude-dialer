import SwiftUI

/// A fold-out card that just shows the campaign script. The part you're on is bold and highlighted.
struct ScriptOutlineCard: View {
    @ObservedObject var coach: CoachModel
    /// The one page version of the script (redraws when Claude finishes writing it).
    @ObservedObject private var pages = ScriptPage.shared
    @AppStorage(PrefKey.scriptOutlineOpen) private var open = false

    private struct Part: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private var parts: [Part] {
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
                return sections.map { Part(id: Self.stageID(for: $0.title), title: $0.title, text: $0.lines.joined(separator: "\n")) }
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
    private var currentID: String {
        if coach.status == .ready { return "opening" }
        switch coach.suggestion.stage {
        case "Opener", "Screener", "Gatekeeper", "Voicemail", "Phone tree": return "opening"
        case "Discovery": return "discovery"
        case "Value": return "value"
        case "Closing", "Goal reached": return "closing"
        case "Objection": return "objection"
        case "Exit": return "exit"
        default: return "opening"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("My script").font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(parts) { part in
                    let here = part.id == currentID
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(here ? Brand.blue : .secondary)
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
                    Text("This call list has no script yet. Click its name at the top, then Edit.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard(radius: 10)
    }
}
