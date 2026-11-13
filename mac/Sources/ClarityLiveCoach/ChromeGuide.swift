import SwiftUI

/// A drawn picture guide for Chrome's one setting (View > Developer > Allow JavaScript from
/// Apple Events). Drawn in the app, so it needs no image files and always matches the app's colors.
struct ChromeSettingGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Look at the very top of your screen, not inside the Chrome window.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            step(1, "Click View in the top menu.") {
                HStack(spacing: 12) {
                    Text("Chrome").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Text("View")
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Brand.blue, lineWidth: 1.5))
                    Text("History")
                    Text("Bookmarks")
                }
                .font(.caption)
                .lineLimit(1)
            }

            step(2, "Click Developer, at the bottom of the list.") {
                mockMenu([
                    Row("Always Show Bookmarks Bar", faded: true),
                    Row("Zoom In", faded: true),
                    Row("Zoom Out", faded: true),
                    Row("Cast...", faded: true),
                    Row("Developer", chevron: true, highlight: true),
                ])
            }

            step(3, "Click Allow JavaScript from Apple Events.") {
                mockMenu([
                    Row("View Source", faded: true),
                    Row("Developer Tools", faded: true),
                    Row("Inspect Elements", faded: true),
                    Row("JavaScript Console", faded: true),
                    Row("Allow JavaScript from Apple Events", check: true, highlight: true),
                ])
            }

            Text("A check mark means it's on. If you already see the check mark, you're done.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Pieces

    private struct Row {
        let title: String
        var faded = false
        var check = false
        var chevron = false
        var highlight = false
        init(_ title: String, faded: Bool = false, check: Bool = false, chevron: Bool = false, highlight: Bool = false) {
            self.title = title; self.faded = faded; self.check = check; self.chevron = chevron; self.highlight = highlight
        }
    }

    private func step<Picture: View>(_ number: Int, _ text: String, @ViewBuilder picture: () -> Picture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Brand.blue))
                Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            picture()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                .foregroundStyle(Color.white.opacity(0.9))
        }
    }

    private func mockMenu(_ rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.check ? "✓" : " ").frame(width: 12)
                    Text(row.title).lineLimit(1)
                    Spacer(minLength: 4)
                    if row.chevron { Image(systemName: "chevron.right").font(.caption2) }
                }
                .font(.caption)
                .foregroundStyle(Color.white.opacity(row.faded ? 0.4 : 1))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(row.highlight ? Brand.blue : Color.clear))
            }
        }
    }
}
