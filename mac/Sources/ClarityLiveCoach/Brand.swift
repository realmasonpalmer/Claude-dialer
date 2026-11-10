import SwiftUI
import AppKit

/// Clarity Consulting's look, from clarityconsulting.io: deep navy, bright blue buttons, teal accents.
enum Brand {
    /// Page background on the website's hero and footer. The whole app sits on it.
    static let navy = Color(red: 0x0B / 255, green: 0x15 / 255, blue: 0x33 / 255)
    static let navyNS = NSColor(red: 0x0B / 255, green: 0x15 / 255, blue: 0x33 / 255, alpha: 1)
    /// Cards: a lighter navy, like the website's video panel.
    static let card = Color(red: 0x15 / 255, green: 0x24 / 255, blue: 0x52 / 255)
    /// Thin card edge.
    static let edge = Color.white.opacity(0.08)
    /// "Book a Call" button blue.
    static let blue = Color(red: 0x1F / 255, green: 0x5E / 255, blue: 0xEB / 255)
    /// Highlight teal ("Not updating your CRM.").
    static let teal = Color(red: 0x3C / 255, green: 0xC8 / 255, blue: 0xD4 / 255)
    /// The hero card: navy into blue, like the website's hero.
    static let hero = LinearGradient(
        colors: [Color(red: 0x1A / 255, green: 0x3A / 255, blue: 0x9C / 255), Color(red: 0x12 / 255, green: 0x22 / 255, blue: 0x55 / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension View {
    /// A Clarity card: lighter navy with a thin edge.
    func brandCard(radius: CGFloat = 10) -> some View {
        background(Brand.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Brand.edge))
    }

    /// Navy page, dark mode, blue controls. Put on every window's root view.
    func brandWindow() -> some View {
        tint(Brand.blue)
            .background(Brand.navy)
            .preferredColorScheme(.dark)
    }
}
