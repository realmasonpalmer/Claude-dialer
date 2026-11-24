import AppKit
import SwiftUI

@main
struct ClarityDialerApp: App {
    @State private var store: Store
    @State private var session: Session
    @State private var updater = Updater()
    @State private var scriptSync: ScriptSync
    @State private var review: CallReview

    init() {
        let store = Store()
        _store = State(initialValue: store)
        _session = State(initialValue: Session(store: store))
        _scriptSync = State(initialValue: ScriptSync(store: store))
        _review = State(initialValue: CallReview(store: store))
    }

    var body: some Scene {
        Window("Clarity Dialer", id: "dialer") {
            DialerView()
                .environment(store)
                .environment(session)
                .environment(updater)
                .environment(scriptSync)
                .frame(minWidth: 980, minHeight: 640)
                .brandWindow()
                .task { await session.startSync() }
                .task { await session.checkLinkedInReady() }
                .task {
                    AudioRoute.shared.start()
                    ScreenerListener.shared.askPermission()
                    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated { AudioRoute.shared.stop() }
                    }
                }
                .task { await updater.run() }
                .task { await scriptSync.run() }
                .task { await review.run() }
        }
        Window("Metrics", id: "metrics") {
            MetricsView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 520)
                .brandWindow()
        }
        .keyboardShortcut("m", modifiers: [.command, .shift])
        Settings {
            SettingsView()
                .environment(store)
                .brandWindow()
        }
    }
}

/// Shared look: one accent, quiet surfaces.
/// Clarity's look (see Brand.swift), in the few names the views use.
enum Look {
    static let accent = Brand.blue
    static let card = Brand.card
    static let radius: CGFloat = CardStyle.radius
}

/// A Clarity card. `script`: the script's own card (solid navy-blue with the teal edge).
struct Card<Content: View>: View {
    var script = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(CardStyle.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(script ? Brand.scriptCard : Brand.card, in: RoundedRectangle(cornerRadius: Look.radius))
            .overlay(alignment: .leading) {
                if script { Rectangle().fill(Brand.teal).frame(width: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Look.radius))
            .overlay(RoundedRectangle(cornerRadius: Look.radius)
                .stroke(script ? Brand.blue.opacity(0.45) : Brand.edge, lineWidth: script ? 1 : 0.5))
    }
}
