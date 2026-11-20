import SwiftUI

/// One click from the Script menu: Claude reads who's on the Salesforce list in use, writes the whole
/// script on the cold call backbone, saves it and switches the coach to it. Nothing to fill in.
struct ScriptMakerView: View {
    @EnvironmentObject var campaigns: CampaignStore
    @Environment(\.dismiss) private var dismiss
    /// "Look it over": opens the full script editor.
    var onEdit: (Campaign) -> Void

    enum Step { case reading, writing, done, failed(String) }
    @State private var step = Step.reading
    @State private var words = 0
    @State private var started = Date()
    @State private var task: Task<Void, Never>?
    @State private var made: Campaign?

    var body: some View {
        let list = campaigns.selected
        VStack(alignment: .leading, spacing: 14) {
            Text("Write my script").font(.title2.weight(.semibold))
            Text(list.listName.isEmpty
                 ? "Pick a Salesforce list at the top first. Claude writes the script for the people on it."
                 : "For the people on \(list.listName). Claude reads who they are and writes everything the coach says: the opener, questions, answers to pushback and the meeting ask.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let secs = Int(ctx.date.timeIntervalSince(started))
                HStack(spacing: 8) {
                    switch step {
                    case .reading:
                        ProgressView().controlSize(.small)
                        Text("1 of 2: Reading who's on your list...")
                    case .writing:
                        ProgressView().controlSize(.small)
                        Text("2 of 2: Writing your script... \(words) words · \(secs / 60):\(String(format: "%02d", secs % 60))")
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Your script is ready. The coach is using it now.")
                    case .failed(let why):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(why).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.callout.weight(.semibold).monospacedDigit())
            }
            Text("Takes 1 to 3 minutes. You can keep calling with your old script while it writes.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if case .done = step, let made {
                    Button("Look it over") { dismiss(); onEdit(made) }
                }
                Spacer()
                switch step {
                case .done:
                    Button("Start calling") { dismiss() }
                        .buttonStyle(BrandPrimaryButton(color: .green)).keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { dismiss() }
                    Button("Try again") { run() }.buttonStyle(BrandPrimaryButton()).keyboardShortcut(.defaultAction)
                default:
                    Button("Stop") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { if campaigns.selected.listViewID.isEmpty { step = .failed("Pick a Salesforce list at the top first.") } else { run() } }
        .onDisappear { if case .done = step {} else { task?.cancel() } }
    }

    private func run() {
        let base = campaigns.selected
        started = Date()
        words = 0
        step = .reading
        task = Task { @MainActor in
            do {
                let who = try await ListProfile.describe(object: base.listObject, viewID: base.listViewID)
                if Task.isCancelled { return }
                step = .writing
                let lists = (try? await Salesforce.listViews()) ?? []
                let list = lists.first { $0.id.prefix(15) == base.listViewID.prefix(15) }
                let name = base.listName.isEmpty ? "My script" : base.listName
                let text = try await ScriptWriter.write(segment: name, audience: who, list: list, onText: { partial in
                    Task { @MainActor in words = partial.split(separator: " ").count }
                })
                if Task.isCancelled { return }
                var c = Campaign()
                c.name = name
                c.persona = who
                c.pastedScript = text
                c.objective = "Book a free 45 minute AI and customer records health check with Oliver."
                c.listViewID = base.listViewID; c.listObject = base.listObject; c.listName = base.listName
                campaigns.save(c)
                campaigns.selectOnly(c.id)
                made = c
                ActivityLog.add("Script written in one click for \(name) (\(words) words)")
                step = .done
            } catch {
                if !Task.isCancelled { step = .failed("Couldn't write the script: \(error.localizedDescription)") }
            }
        }
    }
}
