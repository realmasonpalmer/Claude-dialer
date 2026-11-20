import SwiftUI

/// "Call Block: 12 / 50 Dials": dials in the 50 minute block running now. One ring per block today.
/// Contacts = dials, texts and LinkedIn notes. The goal is 50 every hour.
/// Below: today's total and how many people are due on each active campaign.
struct DailyGoalCard: View {
    @ObservedObject var touchpoints: Touchpoints
    @ObservedObject var coach: CoachModel
    let activeCampaigns: [Campaign]
    @AppStorage("sprintMinutes") private var minutes = 20
    @AppStorage("sprintTarget") private var target = 20
    @AppStorage("sprintCardOpen") private var cardOpen = true

    static let perHour = 50

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Button { cardOpen.toggle() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: cardOpen ? "chevron.down" : "chevron.right").font(CardStyle.chevron)
                                .foregroundStyle(Brand.subtext)
                            Image(systemName: "bolt").font(CardStyle.icon).foregroundStyle(Brand.blue)
                            Text("Call Sprint").font(CardStyle.title).foregroundStyle(Brand.text)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if !cardOpen, coach.blockStartedAt != nil {
                        // Folded and running: status next to the title, the clock on the right.
                        if coach.sprintDone { pill("Complete", Brand.blue) } else { pill("Active", .green) }
                        Spacer(minLength: 0)
                        if let start = coach.blockStartedAt {
                            let total = CoachModel.blockLength
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(Self.clock(min(now.timeIntervalSince(start), total))).font(.title2.weight(.bold)).monospacedDigit()
                                Text("/ " + Self.clock(total)).font(.callout).foregroundStyle(Brand.muted).monospacedDigit()
                            }
                        }
                    }
                    if cardOpen || coach.blockStartedAt == nil { Spacer(minLength: 0) }
                    if cardOpen, coach.sprintDone {
                        pill("Complete", Brand.blue)
                    } else if cardOpen, coach.blockStartedAt != nil {
                        pill("Active", .green)
                    }
                }
                if !cardOpen {
                    if let start = coach.blockStartedAt { foldedActive(start: start, now: now) } else { foldedSetup }
                } else if coach.sprintDone, let start = coach.blockStartedAt {
                    complete(start: start)
                } else if let start = coach.blockStartedAt {
                    active(start: start, now: now)
                } else {
                    setup
                }
            }
            .padding(CardStyle.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .brandCard(radius: CardStyle.radius)
        }
    }

    // MARK: Folded

    /// Not started, folded: the length and the target in one small row.
    private var foldedSetup: some View {
        HStack(spacing: 8) {
            ForEach([20, 30, 50], id: \.self) { m in
                Button { minutes = m; target = m } label: {
                    Text("\(m)m").font(.caption.weight(.semibold))
                        .foregroundStyle(minutes == m ? Brand.text : Brand.subtext)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(minutes == m ? Brand.quiet : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            stepButton("minus") { target = max(5, target - 5) }.controlSize(.small)
            Text("\(target) dials").font(.callout.weight(.semibold)).monospacedDigit()
            stepButton("plus") { target = min(200, target + 5) }.controlSize(.small)
        }
    }

    /// Running, folded: the bar, dials and pace.
    private func foldedActive(start: Date, now: Date) -> some View {
        let total = CoachModel.blockLength
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        let done = touchpoints.dials(from: start, to: now.addingTimeInterval(1))
        let ahead = Int((Double(done) - Double(target) * elapsed / total).rounded())
        let hit = done >= target
        return VStack(spacing: 8) {
            ProgressView(value: min(Double(done) / Double(max(target, 1)), 1)).tint(Brand.blue)
            HStack {
                Text("\(done) / \(target) dials").font(.callout).foregroundStyle(Brand.subtext).monospacedDigit()
                Spacer()
                Text(hit ? "Target hit!" : ahead > 0 ? "\(ahead) ahead of pace" : ahead < 0 ? "\(-ahead) behind pace" : "On pace")
                    .font(.callout).foregroundStyle(hit || ahead > 0 ? Color.green : ahead < 0 ? Color.orange : Brand.subtext)
            }
        }
    }

    // MARK: Before: pick the length and the target

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set your goal. Start dialing. Beat your best.").font(.callout).foregroundStyle(Brand.subtext)
            Text("How long do you want to dial?").font(.callout.weight(.semibold)).foregroundStyle(Brand.text)
            HStack(spacing: 6) {
                ForEach([20, 30, 50], id: \.self) { m in
                    Button {
                        minutes = m
                        target = m // 20, 30 or 50 dials; the rep can change it after

                    } label: {
                        Text("\(m) min").font(.callout.weight(.medium))
                            .foregroundStyle(minutes == m ? Brand.text : Brand.subtext)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(minutes == m ? Brand.quiet : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Dial target").font(.callout.weight(.medium)).foregroundStyle(Brand.text)
                    Spacer()
                    stepButton("minus") { target = max(5, target - 5) }
                    Text("\(target)").font(.title3.weight(.semibold)).monospacedDigit().frame(minWidth: 36)
                    stepButton("plus") { target = min(200, target + 5) }
                }
                Text("Aim for \(target) dials in \(minutes) minutes.").font(.caption).foregroundStyle(Brand.muted)
            }
            .padding(12)
            .background(Brand.navy.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            Label("Sprint starts automatically with your first dial.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(Brand.subtext)
        }
    }

    // MARK: During: time, dials, pace

    private func active(start: Date, now: Date) -> some View {
        let total = CoachModel.blockLength
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        let done = touchpoints.dials(from: start, to: now.addingTimeInterval(1))
        let progress = min(Double(done) / Double(max(target, 1)), 1)
        let expected = Double(target) * elapsed / total
        let ahead = Int((Double(done) - expected).rounded())
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.clock(elapsed)).font(.system(size: 36, weight: .bold)).monospacedDigit()
                    Text("/ " + Self.clock(total)).font(.title3).foregroundStyle(Brand.muted).monospacedDigit()
                }
                Divider().frame(height: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(done) / \(target)").font(.title.weight(.bold)).monospacedDigit()
                    Text("Dials").font(.caption).foregroundStyle(Brand.subtext)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                ProgressView(value: progress).tint(Brand.blue)
                Text("\(Int(progress * 100))%").font(.callout).foregroundStyle(Brand.subtext).monospacedDigit()
            }
            let hit = done >= target
            let tone: Color = hit || ahead > 0 ? .green : (ahead < 0 ? .orange : Brand.subtext)
            Label(hit ? "Target hit! Keep going" : ahead > 0 ? "\(ahead) ahead of pace" : ahead < 0 ? "\(-ahead) behind pace" : "On pace",
                  systemImage: hit ? "party.popper" : ahead >= 0 ? "arrow.up" : "arrow.down")
                .font(.callout.weight(.semibold)).foregroundStyle(tone)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(tone.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                stat(String(format: "%.1f / min", Double(done) / max(elapsed / 60, 0.5)), "Current pace")
                Divider().frame(height: 30)
                stat(String(format: "%.1f / min", Double(target) / (total / 60)), "Target pace")
                Divider().frame(height: 30)
                stat(Self.clock(total - elapsed), "Time left")
            }
        }
    }

    /// Time's up: the totals, and New Sprint. Calling carries on regardless.
    private func complete(start: Date) -> some View {
        let total = CoachModel.blockLength
        let done = touchpoints.dials(from: start, to: start.addingTimeInterval(total))
        return VStack(alignment: .leading, spacing: 12) {
            Text("Sprint Complete").font(.title2.weight(.bold))
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(done) / \(target)").font(.title.weight(.bold)).monospacedDigit()
                    Text("Dials").font(.caption).foregroundStyle(Brand.subtext)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(Self.clock(total)).font(.title.weight(.bold)).monospacedDigit()
                    Text("Time").font(.caption).foregroundStyle(Brand.subtext)
                }
                Spacer(minLength: 0)
            }
            Label(done >= target ? "Target achieved" : "\(target - done) short of the target",
                  systemImage: done >= target ? "checkmark.circle.fill" : "flag")
                .font(.callout.weight(.semibold)).foregroundStyle(done >= target ? Color.green : Brand.subtext)
            Button("New Sprint") { coach.newSprint() }.buttonStyle(BrandPrimaryButton())
        }
    }

    // MARK: Pieces

    private func pill(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.callout.weight(.semibold)).frame(width: 30, height: 30)
                .background(Brand.quiet, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Brand.subtext)
        }
        .frame(maxWidth: .infinity)
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// A small ring that fills as the hour's contacts add up, and turns green when it closes.
struct HourRing: View {
    let progress: Double

    var body: some View {
        let done = progress >= 1
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(progress, 1))
                .stroke(done ? Color.green : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
        }
        .frame(width: 10, height: 10)
        .help(done ? "Goal hit this hour" : "\(Int(progress * 100))% of the hour's goal")
    }
}

/// The 50 minute blocks started today, saved so the rings survive a restart.
enum BlockLog {
    private static let key = "blockStarts"

    static func today() -> [Date] {
        let all = (UserDefaults.standard.array(forKey: key) as? [Double]) ?? []
        return all.map { Date(timeIntervalSince1970: $0) }.filter { Calendar.current.isDateInToday($0) }
    }

    static func add(_ start: Date) {
        let kept = today().map(\.timeIntervalSince1970) // drops earlier days
        UserDefaults.standard.set(kept + [start.timeIntervalSince1970], forKey: key)
    }

    /// A block counts until 50 minutes pass, the next block starts, or now.
    @MainActor static func end(of start: Date, in blocks: [Date], now: Date) -> Date {
        var end = min(start.addingTimeInterval(CoachModel.blockLength), now)
        if let next = blocks.first(where: { $0 > start }) { end = min(end, next) }
        return end
    }
}
