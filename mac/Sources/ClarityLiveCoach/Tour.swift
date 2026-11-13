import AppKit
import SwiftUI

/// The parts of the screen the first-run tour points at.
enum TourSpot: String {
    case gear, segment, zone, line, script, call, followUp, status, goal, numbers, phone, update
    // The Call lists window
    case listsTable, listsOnOff, listsNew, listsEdit, listsStart
    // The New call list window
    case newName, newList, newWho, newGenerate, newScript, newSave
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

    /// The same, for a spot inside the scrolling middle: the tour scrolls it into view first.
    func tourScrollSpot(_ spot: TourSpot) -> some View {
        tourSpot(spot).id(spot.rawValue)
    }
}

/// One step of the tour.
struct TourStep {
    let spot: TourSpot
    /// Which part of the tour this is in ("Make a call"). Steps in a part are numbered by themselves.
    let part: String
    let title: String
    let text: String
    var corner: CGFloat = 12
    var pad: CGFloat = 6
}

enum Tour {
    /// Every part of the screen a new rep will wonder about, in the order they use it.
    /// One short idea per step, in plain words.
    static let steps: [TourStep] = [
        // Part 1
        TourStep(spot: .gear, part: "Get ready", title: "Set up first",
                 text: "Click the gear, then Set up. Do each step one time. Each one turns green when it's done.",
                 corner: 20, pad: 8),
        TourStep(spot: .segment, part: "Get ready", title: "Pick who to call",
                 text: "A call list is people to call, plus what to say to them. Pick one here and its people load.",
                 corner: 10, pad: 8),
        TourStep(spot: .zone, part: "Get ready", title: "Pick where to call",
                 text: "Call just one time zone. Or pick \"Start in the East, go West\" to call the East Coast first.",
                 corner: 10, pad: 8),
        // Part 2
        TourStep(spot: .line, part: "Make a call", title: "Say this",
                 text: "Your next line shows here, big. Read it out loud. It changes each time they talk.",
                 corner: 16, pad: 4),
        TourStep(spot: .script, part: "Make a call", title: "See your whole script",
                 text: "Click here to open it. The part you're on lights up, so you always know where you are."),
        TourStep(spot: .call, part: "Make a call", title: "Click Call",
                 text: "The big button calls this person. The small button skips to the next person."),
        TourStep(spot: .call, part: "Make a call", title: "While you talk",
                 text: "The app listens and knows when the call ends. If it ever misses, click End call. If it misses a voicemail, click Voicemail."),
        TourStep(spot: .call, part: "Make a call", title: "No answer?",
                 text: "The app calls them one more time. Then it counts down and calls the next person. Click Wait to stop it."),
        // Part 3
        TourStep(spot: .followUp, part: "After the call", title: "Send the follow-up",
                 text: "Left a voicemail? Your text and LinkedIn note show up here. One click sends each one.",
                 corner: 14),
        TourStep(spot: .status, part: "After the call", title: "Say how it went",
                 text: "A card shows up for each person. Pick what happened and click Save. It saves to Salesforce.",
                 corner: 14),
        // Part 4
        TourStep(spot: .goal, part: "Keep score", title: "Close your rings",
                 text: "Aim for 50 an hour. Each ring fills as you go. Try to beat yesterday.",
                 corner: 14),
        TourStep(spot: .numbers, part: "Keep score", title: "See your numbers",
                 text: "Your calls, texts, notes and meetings. Click it to see more.",
                 corner: 14),
        TourStep(spot: .update, part: "Keep score", title: "Stay up to date",
                 text: "A blue bar shows at the top when there's a new version. Click Update now between calls. It takes 2 minutes.",
                 corner: 10),
    ]

    /// "MAKE A CALL · 2 OF 5": where this step is inside its part.
    /// The Call lists window: what a call list is, and how to make, change and start one.
    static let listSteps: [TourStep] = [
        TourStep(spot: .listsTable, part: "Call lists", title: "Your call lists",
                 text: "A call list is people to call (a Salesforce list) plus what to say to them (a script). Each row shows who it's for and how many people are on it.",
                 corner: 10),
        TourStep(spot: .listsOnOff, part: "Call lists", title: "Turn lists on and off",
                 text: "Up to 3 can be on. Only lists that are on show in the menu at the top of the coach."),
        TourStep(spot: .listsNew, part: "Call lists", title: "Make a new one",
                 text: "Click New call list. Pick a Salesforce list, say who the people are, and Claude writes the script."),
        TourStep(spot: .listsEdit, part: "Call lists", title: "Change one",
                 text: "Pick a list and click Edit to change its name, its Salesforce list or its script."),
        TourStep(spot: .listsStart, part: "Call lists", title: "Start calling",
                 text: "Pick a list and click here, or double-click it. Its people open in Chrome and the coach uses its script."),
    ]

    /// The New call list window: name, Salesforce list, who they are, the script, save.
    static let newListSteps: [TourStep] = [
        TourStep(spot: .newName, part: "New call list", title: "1. Name it",
                 text: "A short name you'll know at a glance, like Tax firm owners."),
        TourStep(spot: .newList, part: "New call list", title: "2. Pick who to call",
                 text: "Pick the Salesforce list of people to call. To change who's on it, change the list view in Salesforce."),
        TourStep(spot: .newWho, part: "New call list", title: "3. Say who they are",
                 text: "This fills from Salesforce by itself when you pick a list: their titles, levels, industries and states."),
        TourStep(spot: .newGenerate, part: "New call list", title: "4. The script writes itself",
                 text: "It starts as soon as you pick a list and takes about 1 to 2 minutes. Click Stop to change something, then Generate script to write it again."),
        TourStep(spot: .newScript, part: "New call list", title: "Read it over",
                 text: "Change anything you like. Or paste your own script here instead."),
        TourStep(spot: .newSave, part: "New call list", title: "Save",
                 text: "Click Save. Then pick it at the top of the coach, or click Start calling."),
    ]

    static func label(for number: Int, in steps: [TourStep] = Tour.steps) -> String {
        let step = steps[number - 1]
        let inPart = steps.indices.filter { steps[$0].part == step.part }
        let place = (inPart.firstIndex(of: number - 1) ?? 0) + 1
        return "\(step.part) · \(place) of \(inPart.count)"
    }
}

/// The tour on top of the coach: a welcome card, then one spot at a time with the rest dimmed.
/// `step` 0 is the welcome card; 1...n are the steps. nil = no tour.
struct TourOverlay: View {
    @Binding var step: Int?
    let spots: [TourSpot: Anchor<CGRect>]
    /// Which tour: the coach (default), the Call lists window, or New call list.
    var steps: [TourStep] = Tour.steps
    var onFinish: () -> Void

    var body: some View {
        GeometryReader { proxy in
            if let step {
                if step == 0 {
                    welcome
                } else {
                    let s = steps[step - 1]
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
                Text("This app dials for you, listens to the call, and shows you what to say next.\n\nHere's a 2 minute tour of every button.")
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
                        y: hole.map { below ? $0.maxY + 16 : max(16, $0.minY - 16 - 170) } ?? size.height / 2 - 75)
        }
        .contentShape(Rectangle()) // the coach underneath can't be clicked during the tour
    }

    private func tip(_ s: TourStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Tour.label(for: number, in: steps).uppercased())
                .font(.caption2.weight(.semibold)).tracking(0.6)
                .foregroundStyle(Color.accentColor)
            Text(s.title).font(.headline)
            Text(s.text).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                if number > 1 {
                    Button("Back") { go(number - 1) }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(number) of \(steps.count)")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                let last = number == steps.count
                if !last {
                    Button("Skip") { finish() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Button(last ? (steps.count == Tour.steps.count ? "Start calling" : "Got it") : "Next") { last ? finish() : go(number + 1) }
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
