import AppKit
import SwiftUI

/// The parts of the screen the first-run tour points at.
enum TourSpot: String {
    case gear, segment, line, call, followUp, goal
}

/// Where each spot is on screen, collected from the views that mark themselves with `.tourSpot`.
struct TourSpotKey: PreferenceKey {
    static var defaultValue: [TourSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourSpot: Anchor<CGRect>], nextValue: () -> [TourSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Marks this view as a spot the tour can point at.
    func tourSpot(_ spot: TourSpot) -> some View {
        anchorPreference(key: TourSpotKey.self, value: .bounds) { [spot: $0] }
    }
}

/// One step of the tour.
struct TourStep {
    let spot: TourSpot
    let section: String
    let title: String
    let text: String
    let corner: CGFloat
    let pad: CGFloat
}

enum Tour {
    static let steps: [TourStep] = [
        TourStep(spot: .gear, section: "Setup", title: "Set up first",
                 text: "Click the gear. Import your team keys, do the audio check and turn on one Chrome setting.",
                 corner: 20, pad: 8),
        TourStep(spot: .segment, section: "Dialing · 1 of 5", title: "Pick a call segment",
                 text: "Each call segment has its own list and script. Pick one, and its list opens.",
                 corner: 10, pad: 8),
        TourStep(spot: .line, section: "Dialing · 2 of 5", title: "Say this",
                 text: "Your next line shows here, big. Just read it out loud. It changes when they talk.",
                 corner: 16, pad: 4),
        TourStep(spot: .call, section: "Dialing · 3 of 5", title: "Click Call",
                 text: "The app dials, listens and coaches you. No answer? It calls back once by itself.",
                 corner: 12, pad: 6),
        TourStep(spot: .followUp, section: "Dialing · 4 of 5", title: "Send the follow-up",
                 text: "Left a voicemail? Your text and LinkedIn note show up here. One click sends them.",
                 corner: 14, pad: 6),
        TourStep(spot: .goal, section: "Dialing · 5 of 5", title: "Close your rings",
                 text: "Aim for 50 an hour. Each ring fills as you go. Try to beat yesterday.",
                 corner: 14, pad: 6),
    ]
}

/// The tour on top of the coach: a welcome card, then one spot at a time with the rest dimmed.
/// `step` 0 is the welcome card; 1...n are the steps. nil = no tour.
struct TourOverlay: View {
    @Binding var step: Int?
    let spots: [TourSpot: Anchor<CGRect>]
    var onFinish: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if let step {
                if step == 0 {
                    welcome
                } else {
                    let s = Tour.steps[step - 1]
                    let hole = spots[s.spot].map { proxy[$0].insetBy(dx: -s.pad, dy: -s.pad) }
                    spotlight(s, number: step, hole: hole, size: proxy.size)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: step)
    }

    // MARK: Welcome

    private var welcome: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.45))
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                Text("Welcome").font(.title2.weight(.semibold))
                Text("This app dials for you, listens to the call, and shows you what to say next.\n\nHere's a 1 minute tour.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { go(1) } label: {
                    Text("Start the tour").font(.callout.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton(prominent: true))
                .keyboardShortcut(.defaultAction)
                Button("Not now") { finish() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 300)
            .background(card)
        }
        .transition(.opacity)
    }

    // MARK: A step

    private func spotlight(_ s: TourStep, number: Int, hole: CGRect?, size: CGSize) -> some View {
        let below = (hole?.maxY ?? 0) < size.height * 0.6
        return ZStack(alignment: .topLeading) {
            // Everything dimmed except the spot (or all of it, if that part isn't on screen right now).
            Dimmer(hole: hole ?? .zero, corner: s.corner)
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
            if let hole {
                RoundedRectangle(cornerRadius: s.corner)
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .shadow(color: .white.opacity(0.3), radius: 9)
                    .frame(width: hole.width, height: hole.height)
                    .offset(x: hole.minX, y: hole.minY)
            }
            tip(s, number: number)
                .frame(width: min(300, size.width - 32))
                .offset(x: (size.width - min(300, size.width - 32)) / 2,
                        y: hole.map { below ? $0.maxY + 16 : max(16, $0.minY - 16 - 150) } ?? size.height / 2 - 75)
        }
        .contentShape(Rectangle()) // the coach underneath can't be clicked during the tour
    }

    private func tip(_ s: TourStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(s.section.uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.6)
                .foregroundStyle(Color.accentColor)
            Text(s.title).font(.headline)
            Text(s.text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                ForEach(1...Tour.steps.count, id: \.self) { i in
                    Capsule()
                        .fill(i == number ? Color.primary : Color.secondary.opacity(0.35))
                        .frame(width: i == number ? 16 : 6, height: 6)
                }
                Spacer()
                let last = number == Tour.steps.count
                if !last {
                    Button("Skip") { finish() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Button(last ? "Start calling" : "Next") { last ? finish() : go(number + 1) }
                    .buttonStyle(PillButton(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 9)
        }
        .padding(16)
        .background(card)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(white: 0.19))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
    }

    private func go(_ next: Int) { step = next }

    private func finish() {
        step = nil
        onFinish()
    }
}

/// The whole area, with a rounded hole cut out where the spot is.
private struct Dimmer: Shape {
    var hole: CGRect
    var corner: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if hole.width > 0 { p.addRoundedRect(in: hole, cornerSize: CGSize(width: corner, height: corner), style: .continuous) }
        return p
    }
}

/// A white pill button, like the mockups.
private struct PillButton: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .foregroundStyle(Color.black)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

/// Sample info for the walkthrough, shown only while it's open (no list is loaded on a new install).
enum TourSample {
    static let name = "Dana Whitfield"
    static let next = "Raj"
    static let line = "Hi Dana, it's \(Prefs.repName.isEmpty ? "Mason" : Prefs.repName) with Clarity Consulting. I'm calling to invite you to lunch with our managing partner, Oliver. Got twenty seconds?"

    static var followUp: FollowUp {
        var f = FollowUp()
        f.prospect = name
        f.phone = "(503) 555-0142"
        f.text = "Hi Dana, \(Prefs.repName.isEmpty ? "Mason" : Prefs.repName) with Clarity. Just tried you. Would lunch with Oliver work one day next week?"
        f.linkedin = "Hi Dana, I just tried calling. Would be glad to connect."
        f.textDue = true
        f.linkedInDue = true
        return f
    }

    static let steps: [(title: String, done: Bool)] = [("Call twice", true), ("Voicemail", true), ("Text", false), ("LinkedIn", false)]
}
