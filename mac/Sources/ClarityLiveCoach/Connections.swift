import AppKit
import Combine

/// Whether Salesforce and Aircall are connected, as something SwiftUI can watch. The checks
/// themselves are cheap (the keychain is cached), but views didn't know when they changed, so
/// labels could stay stale. Checked every 2 seconds and whenever the app comes to the front;
/// only a real change redraws anything.
@MainActor
final class Connections: ObservableObject {
    static let shared = Connections()

    @Published private(set) var salesforce = Salesforce.isConnected
    @Published private(set) var aircall = Aircall.isSetUp
    @Published private(set) var aircallCalls = Aircall.canPlaceCalls

    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in Connections.shared.refresh() }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in Connections.shared.refresh() }
        }
    }

    func refresh() {
        if salesforce != Salesforce.isConnected { salesforce = Salesforce.isConnected }
        if aircall != Aircall.isSetUp { aircall = Aircall.isSetUp }
        if aircallCalls != Aircall.canPlaceCalls { aircallCalls = Aircall.canPlaceCalls }
    }
}
