import SwiftUI

/// Results and evidence-based script suggestions for the selected campaign.
struct ScriptLabView: View {
    @ObservedObject var lab: CallLab
    @EnvironmentObject var campaigns: CampaignStore
    @State private var confirmClear = false

    private var campaign: Campaign { campaigns.selected }
    private var stats: LabStats { lab.stats(for: campaign) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if stats.calls == 0 {
                    Text("Make some calls. Every call someone answers is scored automatically and shows up here.")
                        .foregroundStyle(.secondary)
                } else {
                    numbers
                    funnel
                    table("Openers", stats.openers)
                    table("Objections", stats.objections)
                    if stats.versions.count > 1 { table("Script versions", stats.versions) }
                }
                suggestionsSection
                privacy
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear {
            lab.markSeen()
            keepWindowsOnTop()
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Script Lab").font(.title2.weight(.semibold))
            Text("\(campaign.name) · version \(campaign.version)").foregroundStyle(.secondary)
            Text("How calls are scored: \(CallScore.explanation)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var numbers: some View {
        HStack(spacing: 12) {
            tile("\(stats.calls)", "answered calls")
            tile("\(stats.avgScore)", "average score")
            tile("\(stats.goodRate)%", "good calls")
            tile("\(stats.goalRate)%", "goal reached")
        }
    }

    private var funnel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How far calls get").font(.headline)
            ForEach(stats.funnel) { step in
                HStack {
                    Text(step.stage).frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(4, geo.size.width * CGFloat(step.rate) / 100))
                    }
                    .frame(height: 10)
                    Text("\(step.rate)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }

    private func table(_ title: String, _ rows: [LabStats.Row]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("Not enough data yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Calls"); Text("Avg score"); Text("Good calls")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.label)
                            Text("\(row.calls)").monospacedDigit()
                            Text("\(row.avgScore)").monospacedDigit()
                            Text("\(row.goodRate)%").monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private var suggestionsSection: some View {
        let mine = lab.suggestions(for: campaign)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Suggested improvements").font(.headline)
            Text("Claude checks your results every \(CallLab.autoEvery) calls (first after \(CallLab.minimumCalls)) and suggests up to 3 changes, each with the numbers behind it. Nothing changes until you click Apply.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Check now") { Task { await lab.analyze(campaign) } }
                    .disabled(lab.analyzing || stats.calls < CallLab.minimumCalls)
                if lab.analyzing {
                    ProgressView().controlSize(.small)
                    Text("Claude is studying your calls...").font(.callout).foregroundStyle(.secondary)
                } else if stats.calls < CallLab.minimumCalls {
                    Text("\(CallLab.minimumCalls - stats.calls) more answered calls needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = lab.analysisError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
            ForEach(mine) { suggestion in
                card(suggestion)
            }
        }
    }

    private func card(_ s: ScriptSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.title).font(.headline)
                Text("\(s.confidence) confidence")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(confidenceColor(s.confidence).opacity(0.2), in: Capsule())
                Spacer()
            }
            Text("Why: \(s.why)").font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(s.suggested)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
            HStack {
                Button("Apply to script") { lab.apply(s, to: campaigns) }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { lab.dismiss(s) }
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Learn from my calls", isOn: $lab.learning)
            Text("Saves each call's score and a short summary on this Mac, with no names. No recordings or transcripts are kept. History older than 90 days is deleted.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete call history", role: .destructive) { confirmClear = true }
                .confirmationDialog("Delete all call history and suggestions?", isPresented: $confirmClear) {
                    Button("Delete", role: .destructive) { lab.clearHistory() }
                }
        }
    }

    // MARK: Small pieces

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func confidenceColor(_ c: String) -> Color {
        switch c {
        case "high": return .green
        case "medium": return .orange
        default: return .secondary
        }
    }
}
