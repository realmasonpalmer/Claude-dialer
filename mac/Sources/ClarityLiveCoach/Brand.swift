import SwiftUI

/// Clarity Consulting's look, from clarityconsulting.io: deep navy, bright blue buttons, teal accents.
enum Brand {
    /// Page background on the website's hero and footer.
    static let navy = Color(red: 0x0B / 255, green: 0x15 / 255, blue: 0x33 / 255)
    /// "Book a Call" button blue.
    static let blue = Color(red: 0x1F / 255, green: 0x5E / 255, blue: 0xEB / 255)
    /// Highlight teal ("Not updating your CRM.").
    static let teal = Color(red: 0x3C / 255, green: 0xC8 / 255, blue: 0xD4 / 255)
}

/// The Clarity "C" mark: a blue-to-teal ring open on the right, with a dot in the middle.
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.12, to: 0.88)
                .stroke(
                    LinearGradient(colors: [Brand.teal, Brand.blue], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: size * 0.22, lineCap: .round)
                )
            Circle()
                .fill(Brand.teal)
                .frame(width: size * 0.28, height: size * 0.28)
        }
        .frame(width: size, height: size)
    }
}

/// The navy strip across the top of the main window, like the website's header.
struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            BrandMark(size: 18)
            Text("Clarity").font(.system(size: 14, weight: .semibold))
                + Text(" Live Coach").font(.system(size: 14, weight: .regular))
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Brand.navy)
    }
}
