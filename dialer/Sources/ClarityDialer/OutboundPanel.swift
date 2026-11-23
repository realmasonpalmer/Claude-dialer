import SwiftUI

/// Outbound Settings, at the bottom of the dialer: numbers, calling options, follow-up.
/// The same settings as Settings > Calling, where you use them, between calls.
struct OutboundPanel: View {
    @Environment(Store.self) private var store
    @Environment(Session.self) private var session
    @AppStorage("outboundOpen") private var open = true
    @AppStorage("linkedInBotOn") private var linkedInOn = true
    @State private var numbers: [Aircall.Number] = []

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Image(systemName: "slider.horizontal.3").foregroundStyle(Look.accent)
                    Text("Outbound Settings").font(.headline)
                    Spacer()
                    if !open { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { callsFrom; textsFrom }
                    VStack(alignment: .leading, spacing: 12) { callsFrom; textsFrom }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { callingBox; followUpBox }
                    VStack(alignment: .leading, spacing: 12) { callingBox; followUpBox }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .task { numbers = (try? await Aircall.numbers()) ?? [] }
        // Who's on the list depends on these: reload between calls so the change shows.
        .onChange(of: store.settings.mobileOnly) { reloadIfIdle() }
    }

    private var summary: String {
        let s = store.settings
        return [s.autoDial ? "Auto dial" : "Manual dial", s.callTwice ? "Call twice" : nil,
                s.mobileOnly ? "Mobile only" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func reloadIfIdle() {
        guard let list = session.list, [.ready, .finished].contains(session.state) else { return }
        Task { await session.load(list) }
    }

    // MARK: Numbers

    private var callsFrom: some View {
        @Bindable var store = store
        return field("CALLS GO OUT FROM", icon: "phone") {
            Picker("", selection: $store.settings.fromNumberID) {
                Text("Choose a number").tag(Int?.none)
                ForEach(numbers) { Text("\($0.name)  \($0.digits)").tag(Int?.some($0.id)) }
            }
            .labelsHidden()
            .onChange(of: store.settings.fromNumberID) { _, id in
                store.settings.fromNumberDigits = numbers.first { $0.id == id }?.digits ?? ""
            }
        }
    }

    private var textsFrom: some View {
        @Bindable var store = store
        return field("TEXTS GO OUT FROM", icon: "bubble.left") {
            Picker("", selection: $store.settings.textNumberID) {
                Text("Same as calls").tag(Int?.none)
                ForEach(numbers) { Text("\($0.name)  \($0.digits)").tag(Int?.some($0.id)) }
            }
            .labelsHidden()
        }
    }

    // MARK: Options

    private var callingBox: some View {
        @Bindable var store = store
        return box("Calling Options", icon: "phone") {
            check("Auto Dial", $store.settings.autoDial, "Calls the next person by itself after a countdown. ⌘P pauses.")
            check("Call Twice", $store.settings.callTwice, "If they don't pick up, call once more right away.")
            check("Mobile Only", $store.settings.mobileOnly, "Skip anyone with no Mobile in Salesforce.")
        }
    }

    private var followUpBox: some View {
        @Bindable var store = store
        return box("Follow-Up", icon: "paperplane") {
            check("Auto Voicemail Drop", $store.settings.voicemailDrop, "Drops that day's recording (Voicemail 1 on Day 1, Voicemail 2 on Day 3). Press ⌘D at the beep.")
            check("Auto LinkedIn Connect", $linkedInOn, "On Day 1, sends the connection request with your note in Chrome while the call rings. Max 20 a day, 100 a week; pauses itself on any LinkedIn warning.")
            Label("Texts and LinkedIn follow the Day 1 / 3 / 5 sequence", systemImage: "calendar")
                .font(.callout).foregroundStyle(.secondary)
            SettingsLink { Text("Edit sequence…") }
                .buttonStyle(.link).font(.callout)
        }
    }

    // MARK: Pieces

    private func check(_ title: String, _ value: Binding<Bool>, _ help: String) -> some View {
        Toggle(title, isOn: value).toggleStyle(.checkbox).help(help)
    }

    private func field<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func box<C: View>(_ title: String, icon: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.body.weight(.semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: Look.radius).strokeBorder(.quaternary))
    }

}
