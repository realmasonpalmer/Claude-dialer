import SwiftUI

@main
struct ClarityDialerApp: App {
    @State private var store: Store
    @State private var session: Session
    @State private var updater = Updater()

    init() {
        let store = Store()
        _store = State(initialValue: store)
        _session = State(initialValue: Session(store: store))
    }

    var body: some Scene {
        Window("Clarity Dialer", id: "dialer") {
            DialerView()
                .environment(store)
                .environment(session)
                .environment(updater)
                .frame(minWidth: 980, minHeight: 640)
                .task { await session.startSync() }
                .task { await updater.run() }
        }
        Window("Metrics", id: "metrics") {
            MetricsView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 520)
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Shared look: one accent, quiet surfaces.
enum Look {
    static let accent = Color.accentColor
    static let card = Color(nsColor: .controlBackgroundColor)
    static let radius: CGFloat = 12
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Look.card, in: RoundedRectangle(cornerRadius: Look.radius))
            .overlay(RoundedRectangle(cornerRadius: Look.radius).strokeBorder(.quaternary))
    }
}
