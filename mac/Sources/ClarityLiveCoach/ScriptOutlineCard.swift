import SwiftUI

/// A fold-out card that just shows the campaign script. The part you're on is bold and highlighted.
struct ScriptOutlineCard: View {
    @ObservedObject var coach: CoachModel
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
        if !c.pastedScript.trimmed.isEmpty { list.insert(Part(id: "script", title: "Your script", text: c.pastedScript), at: 0) }
        return list.filter { !$0.text.trimmed.isEmpty }
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
                    Text("Script").font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(parts) { part in
                    let here = part.id == currentID
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(here ? Color.accentColor : .secondary)
                        Text(part.text.trimmed)
                            .font(.callout.weight(here ? .bold : .regular))
                            .foregroundStyle(here ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(here ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                if parts.isEmpty {
                    Text("No script written for this segment yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
