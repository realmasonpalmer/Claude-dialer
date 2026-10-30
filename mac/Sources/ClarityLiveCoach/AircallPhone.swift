import SwiftUI
import WebKit

/// Aircall's own phone (Aircall Workspace, workspace.aircall.io) running inside the coach.
/// The rep signs in once; after that the coach dials through the Aircall API and the call
/// rings out here. No Aircall desktop app and no Aircall panel in Chrome needed.
/// Calls are real Aircall calls, so they log to Salesforce like always.
@MainActor
final class AircallPhone: NSObject, ObservableObject, WKUIDelegate, WKNavigationDelegate {
    static let shared = AircallPhone()
    nonisolated static let address = URL(string: "https://workspace.aircall.io")!

    /// On by default. Off = use the Aircall desktop app or the Aircall panel in Chrome instead.
    nonisolated static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "appPhone") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appPhone") }
    }

    /// The phone is shown big (to sign in) or tucked away (while calling).
    @Published var shown = false

    let webView: WKWebView
    private var popups: [NSWindow] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // stays signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 376, height: 600), configuration: config)
        // Aircall supports Chrome; look like Chrome so it doesn't refuse to load.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
    }

    /// Loads the phone once, when the coach opens.
    func start() {
        guard Self.isOn, webView.url == nil else { return }
        webView.load(URLRequest(url: Self.address))
    }

    func reload() { webView.load(URLRequest(url: Self.address)) }

    // MARK: WKUIDelegate

    /// The phone needs the mic for calls. Only Aircall gets it.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("aircall.io") ? .grant : .deny)
    }

    /// Sign-in pop-ups (like "Sign in with Google") open in their own small window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.uiDelegate = self
        let window = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Sign in"
        window.contentView = popup
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        popups.append(window)
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        popups.removeAll { window in
            guard window.contentView === webView else { return false }
            window.close()
            return true
        }
    }
}

/// The phone on screen. Kept in the coach window even when tucked away,
/// so it keeps running (a hidden page can lose its mic).
struct AircallPhoneView: NSViewRepresentable {
    let phone: AircallPhone

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        place(phone.webView, in: box)
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        if phone.webView.superview !== box { place(phone.webView, in: box) }
    }

    private func place(_ web: WKWebView, in box: NSView) {
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            web.topAnchor.constraint(equalTo: box.topAnchor),
            web.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}

/// "Aircall phone" bar in the coach: Show to sign in, Hide while calling.
struct AircallPhonePanel: View {
    @ObservedObject var phone = AircallPhone.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "phone.circle")
                Text("Aircall phone").font(.callout.weight(.semibold))
                Spacer(minLength: 0)
                if phone.shown {
                    Button("Reload") { phone.reload() }
                }
                Button(phone.shown ? "Hide" : "Show") { phone.shown.toggle() }
            }
            if phone.shown {
                Text("Sign in once. Then set yourself to Available. Calls ring here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Always on screen, just tiny when hidden, so calls keep working.
            AircallPhoneView(phone: phone)
                .frame(height: phone.shown ? 520 : 2)
                .opacity(phone.shown ? 1 : 0.02)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .onAppear { phone.start() }
    }
}
