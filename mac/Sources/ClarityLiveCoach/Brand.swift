import SwiftUI
import AppKit

/// Clarity's navy, blue and teal, calmed down for long reading. Strong color is saved for what
/// matters now: the Call button (blue), labels and the script's edge (teal), problems (orange/red).
enum Brand {
    private static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// Page background: slate navy.
    static let navy = hex(0x111827)
    static let navyNS = NSColor(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1)
    /// Standard cards.
    static let card = hex(0x1B2538)
    /// The script card: solid, no gradient, for reading all call long.
    static let scriptCard = hex(0x202F49)
    /// Quiet buttons (Next, Reload, Hide, Back).
    static let quiet = hex(0x253249)
    /// Decorative borders.
    static let edge = hex(0x303D52)
    /// Control outlines: a step brighter than decorative borders so buttons read as buttons.
    static let controlEdge = hex(0x3E4D66)
    /// Main text: soft white.
    static let text = hex(0xE5EAF2)
    /// Instructions, timestamps, labels.
    static let subtext = hex(0xA7B2C5)
    /// Primary action blue.
    static let blue = hex(0x2563EB)
    /// Teal accent: labels and small highlights.
    static let teal = hex(0x45C3CB)
}

extension View {
    /// A standard card: slightly lighter than the page, with a soft edge.
    func brandCard(radius: CGFloat = 10) -> some View {
        background(Brand.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Brand.edge, lineWidth: 0.5))
    }

    /// Slate navy page, soft white text, quieter secondary text, blue controls.
    /// Put on every window's root view.
    func brandWindow() -> some View {
        tint(Brand.blue)
            .foregroundStyle(Brand.text, Brand.subtext)
            .background(Brand.navy)
            .preferredColorScheme(.dark)
    }
}

/// The one strong action on screen (Call, Redial). Always blue, even when the window isn't in
/// front (the Mac's own blue buttons turn gray then, and the coach floats over Salesforce).
struct BrandPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration)
    }

    private struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brand.blue.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                            in: RoundedRectangle(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.7)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Everything next to the main action (Next, Back, Reload, Hide): a muted surface, soft white
/// label and a clear outline.
struct BrandQuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Body(configuration: configuration)
    }

    private struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? Brand.text : Brand.subtext.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(configuration.isPressed ? Brand.edge : Brand.quiet, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Brand.controlEdge, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
