import SwiftUI

/// 4-7-8 and box breathing, shown over the dialer. A 2-minute session: the circle grows from 40% to
/// 90% while breathing in and shrinks while breathing out; the background fills up and drains with
/// it. Blue = in, mint = hold, lavender = out, amber = second hold.
enum BreathingTechnique: String, Identifiable, CaseIterable {
    case relaxing = "478", box = "4444"
    var id: String { rawValue }

    var title: String { self == .relaxing ? "4-7-8 Breathing" : "Box Breathing" }
    var subtitle: String { self == .relaxing ? "Inhale 4 · Hold 7 · Exhale 8" : "Inhale 4 · Hold 4 · Exhale 4 · Hold 4" }
    var menuLabel: String { self == .relaxing ? "4-7-8 breathing" : "Box breathing" }

    var phases: [BreathPhase] {
        switch self {
        case .relaxing: return [.init(kind: .inhale, seconds: 4), .init(kind: .hold1, seconds: 7), .init(kind: .exhale, seconds: 8)]
        case .box: return [.init(kind: .inhale, seconds: 4), .init(kind: .hold1, seconds: 4), .init(kind: .exhale, seconds: 4), .init(kind: .hold2, seconds: 4)]
        }
    }
}

struct BreathPhase: Equatable {
    enum Kind: Equatable { case inhale, hold1, exhale, hold2 }
    let kind: Kind
    let seconds: Double

    var label: String {
        switch kind {
        case .inhale: return "Breathe in"
        case .exhale: return "Breathe out"
        case .hold1, .hold2: return "Hold"
        }
    }

    var instruction: String {
        switch kind {
        case .inhale: return "Breathe in gently."
        case .hold1: return "Rest softly at the top of your breath."
        case .exhale: return "Let your breath flow out gently."
        case .hold2: return "Rest before your next breath."
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r / 255, green: g / 255, blue: b / 255) }

    var color: Color {
        switch kind {
        case .inhale: return Self.rgb(170, 200, 255)
        case .hold1: return Self.rgb(160, 230, 210)
        case .exhale: return Self.rgb(200, 185, 255)
        case .hold2: return Self.rgb(255, 220, 170)
        }
    }
    var secondary: Color {
        switch kind {
        case .inhale: return Self.rgb(145, 180, 255)
        case .hold1: return Self.rgb(140, 210, 190)
        case .exhale: return Self.rgb(180, 165, 235)
        case .hold2: return Self.rgb(235, 200, 150)
        }
    }
    var text: Color {
        switch kind {
        case .inhale: return Self.rgb(100, 150, 240)
        case .hold1: return Self.rgb(80, 190, 160)
        case .exhale: return Self.rgb(160, 130, 230)
        case .hold2: return Self.rgb(230, 180, 100)
        }
    }

    /// Breathing in and holding after it: the circle is big and the background full.
    var expanded: Bool { kind == .inhale || kind == .hold1 }
}

struct BreathingView: View {
    let technique: BreathingTechnique
    var durationSeconds: Double = 120
    let close: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()
    @State private var elapsed: Double = 0
    private let tick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var finished: Bool { elapsed >= durationSeconds }

    /// The phase at this moment and whole seconds left in it (one clock for labels and motion).
    private var current: (phase: BreathPhase, remaining: Int) {
        let pattern = technique.phases
        let cycle = pattern.reduce(0) { $0 + $1.seconds }
        var position = min(elapsed, max(0, durationSeconds - 0.001)).truncatingRemainder(dividingBy: cycle)
        for p in pattern {
            if position < p.seconds { return (p, Int((p.seconds - position).rounded(.up))) }
            position -= p.seconds
        }
        return (pattern[0], Int(pattern[0].seconds))
    }

    /// Size and fill move over the whole inhale/exhale; holds stay put.
    private var movement: Animation? {
        let p = current.phase
        guard !reduceMotion, p.kind == .inhale || p.kind == .exhale else { return nil }
        return .timingCurve(0.4, 0, 0.2, 1, duration: p.seconds)
    }

    var body: some View {
        let (phase, remaining) = current
        let secondsLeft = max(0, Int((durationSeconds - elapsed).rounded(.up)))
        ZStack {
            // Dimmed, blurred app behind.
            Rectangle().fill(.black.opacity(0.35)).background(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture {}

            ZStack {
                Color(red: 250 / 255, green: 250 / 255, blue: 1)

                // Background fill: rises while breathing in, drains while breathing out.
                GeometryReader { g in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(colors: [phase.color.opacity(0.6), phase.color.opacity(0.1)], startPoint: .bottom, endPoint: .top)
                            .frame(height: phase.expanded ? g.size.height : 0)
                            .animation(movement, value: phase.expanded)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: phase.kind)
                    }
                }

                VStack(spacing: 0) {
                    Text(technique.title).font(.system(size: 34, weight: .semibold)).tracking(-0.8)
                        .foregroundStyle(Color(red: 0.19, green: 0.22, blue: 0.27))
                    Text(technique.subtitle).font(.callout).foregroundStyle(Color(red: 0.44, green: 0.47, blue: 0.53)).padding(.top, 10)

                    // The circle: 40% of the stage, growing to 90%.
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [phase.color.opacity(0.65), phase.secondary.opacity(0.55)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: phase.color.opacity(0.45), radius: 22)
                            .frame(width: (phase.expanded ? 0.9 : 0.4) * 200, height: (phase.expanded ? 0.9 : 0.4) * 200)
                            .animation(movement, value: phase.expanded)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: phase.kind)
                        Image(systemName: "wind").font(.system(size: 30, weight: .light)).foregroundStyle(phase.text)
                    }
                    .frame(width: 200, height: 200)
                    .padding(.vertical, 36)

                    Text(finished ? "Session complete" : phase.label)
                        .font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                        .foregroundStyle(phase.text)
                        .id(finished ? "done" : phase.label + "\(phase.kind)")
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 10)))
                    Text(finished ? "Well done" : "\(remaining)s")
                        .font(.title3.monospacedDigit()).foregroundStyle(phase.text)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(.white.opacity(0.4), in: Capsule())
                        .padding(.top, 10)
                    Text(finished ? "Take a moment to notice how you feel." : phase.instruction)
                        .font(.callout).foregroundStyle(Color(red: 0.41, green: 0.45, blue: 0.51)).padding(.top, 16)

                    VStack(spacing: 10) {
                        ProgressView(value: min(elapsed / durationSeconds, 1)).tint(Color(red: 166 / 255, green: 154 / 255, blue: 218 / 255))
                        Text("\(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60)) remaining")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color(red: 0.44, green: 0.48, blue: 0.55))
                        if finished {
                            Button("Start again") { startedAt = Date(); elapsed = 0 }
                                .buttonStyle(BrandPrimaryButton(color: Color(red: 129 / 255, green: 123 / 255, blue: 214 / 255)))
                        }
                        Text("Breathe comfortably. Stop if you feel dizzy or uncomfortable.")
                            .font(.caption2).foregroundStyle(Color(red: 0.44, green: 0.48, blue: 0.55)).padding(.top, 8)
                    }
                    .frame(width: 320)
                    .padding(.top, 24)
                }
                .padding(.horizontal, 24)

                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .medium)).foregroundStyle(Color(red: 0.4, green: 0.44, blue: 0.52))
                        .frame(width: 44, height: 44).background(.white.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.2), radius: 40, y: 24)
            .padding(16)
            .environment(\.colorScheme, .light)
        }
        .onReceive(tick) { _ in
            guard !finished else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) {
                elapsed = min(Date().timeIntervalSince(startedAt), durationSeconds)
            }
        }
    }
}
