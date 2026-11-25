import SwiftUI

/// 4-7-8 and box breathing, shown over the Aircall phone panel in Clarity colors. A 2-minute session: the circle grows from 40% to
/// 90% while breathing in and shrinks while breathing out; the background fills up and drains with
/// it.
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

    /// Clarity colors: blue = in, teal = hold, sky = out, soft teal = second hold.
    var color: Color {
        switch kind {
        case .inhale: return Brand.blue
        case .hold1: return Brand.teal
        case .exhale: return Color(red: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255)
        case .hold2: return Brand.teal.opacity(0.8)
        }
    }
    var secondary: Color {
        switch kind {
        case .inhale: return Brand.teal
        case .hold1: return Brand.blue
        case .exhale: return Brand.blue
        case .hold2: return Brand.blue
        }
    }
    /// Words on the card stay white; the color lives in the circle and the fill.
    var text: Color { Brand.text }

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
            Brand.navy

            // Background fill: rises while breathing in, drains while breathing out.
            GeometryReader { g in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(colors: [phase.color.opacity(0.35), phase.color.opacity(0.03)], startPoint: .bottom, endPoint: .top)
                        .frame(height: phase.expanded ? g.size.height : 0)
                        .animation(movement, value: phase.expanded)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: phase.kind)
                }
            }

            VStack(spacing: 0) {
                Text("CLARITY").font(.caption.weight(.bold)).tracking(3).foregroundStyle(Brand.teal)
                Text(technique.title).font(.system(size: 24, weight: .semibold)).tracking(-0.5)
                    .foregroundStyle(Brand.text).padding(.top, 6)
                Text(technique.subtitle).font(.callout).foregroundStyle(Brand.subtext).padding(.top, 6)

                // The circle: 40% of the stage, growing to 90%.
                ZStack {
                    Circle().stroke(Brand.edge, lineWidth: 1)
                    Circle()
                        .fill(LinearGradient(colors: [phase.color.opacity(0.9), phase.secondary.opacity(0.7)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: phase.color.opacity(0.5), radius: 24)
                        .frame(width: (phase.expanded ? 0.9 : 0.4) * 180, height: (phase.expanded ? 0.9 : 0.4) * 180)
                        .animation(movement, value: phase.expanded)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 1), value: phase.kind)
                    Image(systemName: "wind").font(.system(size: 26, weight: .light)).foregroundStyle(Brand.text)
                }
                .frame(width: 180, height: 180)
                .padding(.vertical, 28)

                Text(finished ? "Session complete" : phase.label)
                    .font(.system(size: 28, weight: .semibold)).tracking(-0.5)
                    .foregroundStyle(Brand.text)
                    .id(finished ? "done" : phase.label + "\(phase.kind)")
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 10)))
                Text(finished ? "Well done" : "\(remaining)s")
                    .font(.title3.monospacedDigit()).foregroundStyle(Brand.text)
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(phase.color.opacity(0.25), in: Capsule())
                    .overlay(Capsule().stroke(phase.color.opacity(0.6), lineWidth: 1))
                    .padding(.top, 10)
                Text(finished ? "Take a moment to notice how you feel." : phase.instruction)
                    .font(.callout).foregroundStyle(Brand.subtext).multilineTextAlignment(.center).padding(.top, 14)

                VStack(spacing: 10) {
                    ProgressView(value: min(elapsed / durationSeconds, 1)).tint(Brand.teal)
                    Text("\(secondsLeft / 60):\(String(format: "%02d", secondsLeft % 60)) remaining")
                        .font(.caption.monospacedDigit()).foregroundStyle(Brand.muted)
                    if finished {
                        Button("Start again") { startedAt = Date(); elapsed = 0 }
                            .buttonStyle(BrandPrimaryButton())
                    }
                    Text("Breathe comfortably. Stop if you feel dizzy or uncomfortable.")
                        .font(.caption2).foregroundStyle(Brand.muted).multilineTextAlignment(.center).padding(.top, 6)
                }
                .frame(maxWidth: 280)
                .padding(.top, 22)
            }
            .padding(.horizontal, 20)

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.subtext)
                    .frame(width: 34, height: 34).background(Brand.quiet, in: Circle())
                    .overlay(Circle().stroke(Brand.controlEdge, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(12)
        }
        .overlay(alignment: .top) { Rectangle().fill(Brand.teal).frame(height: 3) }
        .clipped()
        .environment(\.colorScheme, .dark)
        .onReceive(tick) { _ in
            guard !finished else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) {
                elapsed = min(Date().timeIntervalSince(startedAt), durationSeconds)
            }
        }
    }
}
