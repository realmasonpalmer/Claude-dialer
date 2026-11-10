import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// The coach: one call at a time, the person on screen, and the line to say next.
/// Split by job across the CoachModel+*.swift files. Every stored property lives here.
@MainActor
final class CoachModel: ObservableObject {
    enum Status { case ready, live, paused }
    enum Kind { case opener, reply, screener, voicemail }

    @Published var status: Status = .ready
    @Published var suggestion = Suggestion()
    @Published var kind: Kind = .opener
    @Published var latestProspect = ""
    /// The live transcript lives in its own small model, so a new word only redraws the
    /// transcript, not the whole screen.
    let transcript = LiveTranscript()
    var turns: [Turn] {
        get { transcript.turns }
        set { transcript.turns = newValue }
    }
    var interim: [Speaker: String] {
        get { transcript.interim }
        set { transcript.interim = newValue }
    }
    @Published var latency: Double?
    @Published var problem: String?
    @Published var thinking = false
    /// Who the rep is calling, from the Salesforce tab title (e.g. Lead "Jane Doe").
    @Published var calling: String?
    /// Text from the open Salesforce page, when Chrome allows it.
    @Published var recordDetails: String?
    var tabTicks = 0
    var voicemailScript: Suggestion?   // written ahead of time for this prospect
    var voicemailTask: Task<Void, Never>?
    var voicemailActive = false
    var mailboxFullShown = false

    // MARK: Where the call is

    /// The four steps shown at the top: Opener -> Discovery -> Value -> Close.
    static let journey = ["Opener", "Discovery", "Value", "Close"]
    @Published var journeyStep = 0
    var nextStepName: String? { journeyStep + 1 < Self.journey.count ? Self.journey[journeyStep + 1] : nil }

    /// Lines shown on this call, so Back can show the previous one.
    var history: [(s: Suggestion, kind: Kind)] = []
    @Published var historyIndex: Int?   // nil = showing the newest line
    var canGoBack: Bool { (historyIndex ?? history.count - 1) > 0 }

    /// The rep's Salesforce list, for the Next button.
    let callList = CallList()
    var detailsTask: Task<Void, Never>?
    var listWatcher: AnyCancellable?
    var leadsWatcher: AnyCancellable?
    var leadDetailsWatcher: AnyCancellable?

    // MARK: Lead list (Salesforce) and dialing (Aircall)

    /// The call list from a Salesforce list view. When active, Chrome isn't needed at all.
    let leads = LeadQueue()
    var appliedLeadID: String?
    var pendingDialSince: Date?
    @Published var dialing = false
    @Published var dialError: String?

    // MARK: Status card (Contact: Relationship Status. Lead: Lead Status.)

    /// The Contact or Lead on screen.
    @Published var statusRecordID: String?
    /// What Salesforce says right now (nil = blank or not loaded yet).
    @Published var recordStatus: String?
    /// The record whose status is being saved right now (nil = not saving).
    @Published var savingStatusFor: String?
    /// "Saving..." only for the person on screen.
    var savingStatus: Bool { savingStatusFor != nil && savingStatusFor == statusRecordID }
    @Published var statusMessage: String?

    /// "Contact" or "Lead" for the record on screen.
    var statusObject: String? { statusRecordID.flatMap(Salesforce.objectFor) }

    // MARK: Moving on after a call: send the text, load the next person, count down, dial

    /// The "Double tap" switch next to Auto-dial: on = call each lead twice (redial), off = once.
    var doubleTap: Bool {
        get { Prefs.doubleTap }
        set { Prefs.doubleTap = newValue; objectWillChange.send() }
    }
    /// Dials per lead per visit: 2 with Double tap, otherwise 1.
    var maxAttempts: Int { doubleTap ? 2 : 1 }

    /// The "Auto-dial" switch next to Aircall phone.
    var autoDial: Bool {
        get { Prefs.autoDial }
        set { Prefs.autoDial = newValue; objectWillChange.send() }
    }

    // MARK: Double dial

    /// Calls per lead today, and whether the last call reached a person.
    var attempts: [String: Int] = [:]
    @Published var currentAttemptKey: String?
    @Published var lastCallAnswered = true
    var currentAttempts: Int { currentAttemptKey.flatMap { attempts[$0] } ?? 0 }

    /// After a first try nobody answered (or voicemail), offer to call right back.
    var shouldOfferRedial: Bool {
        status == .ready && currentAttemptKey != nil && !lastCallAnswered && currentAttempts < maxAttempts
            && !(currentAttemptKey.map(DialHistory.isMaxed) ?? false) // last try: no redial
            && !(currentAttemptKey.map(RemovedList.contains) ?? false) // marked Not Quality Prospect / Negative: no redial
    }

    var lastWaitingFor = ""

    var noMobileSkips = 0

    /// After a voicemail: the text and LinkedIn note to send. Stays after the call until checked off.
    @Published var followUp: FollowUp? { didSet { followUpChanged() } }

    /// After a call that's done (no redial): sending the text is the cue to move on.
    @Published var waitingForText = false
    var textWasDone = false

    /// Proven openers, rotated call by call, with your own scoreboard.
    let openers = OpenerBook()
    var callOpener: Opener?   // the opener used on this call
    var goalHit = false
    var sawVoicemail = false
    var stagesSeen: Set<String> = []
    var screenerActive = false       // a screener is talking; wait for the real person
    var openerBeforeScreener: Suggestion?
    var firstProspectAt: Date?
    var lastWordsAt: Date?

    /// Scores every answered call and suggests script improvements over time.
    let lab = CallLab()
    /// Dials, pickups, texts, LinkedIn notes and more, counted on this Mac.
    let touchpoints = Touchpoints()
    /// Real free time from the booking calendar (Calendly or Google), for booking.
    let availability = Availability()
    /// Meeting times already offered on this call, and the next two to offer.
    var offeredTimes: Set<Date> = []
    var codeByDate: [Date: String] = [:]
    @Published var nextOffer: [Date] = []

    var openerStyle: Opener? { openers.rotate ? openers.current : nil }

    @Published private(set) var campaign = Campaign.clarityDiscovery
    var system = CoachPrompt.system(for: .clarityDiscovery)

    func use(_ next: Campaign) {
        touchpoints.currentCampaign = next.name
        guard next != campaign else { return }
        campaign = next
        touchpoints.currentCampaign = next.name
        listDone = false
        system = CoachPrompt.system(for: next)
        if status == .ready { prepareOpener() }
    }

    let capture = CaptureEngine()
    let streams = StreamBox()
    var timer: Timer?
    var startedByHand = false
    var quietTicks = 0
    var reconnects = 0
    var useKeyterms = true // turned off if Deepgram ever rejects them

    var uncoached = ""          // prospect words not yet answered
    var seq = 0                 // newest request id; older ones are stale
    var coachTask: Task<Void, Never>?
    var shownID = 0
    var shownAt = Date.distantPast
    var pending: (id: Int, suggestion: Suggestion)?
    var holdTask: Task<Void, Never>?
    var timedID = 0

    // Starting early: when the prospect's sentence sounds finished, Claude starts writing before
    // the transcriber confirms they stopped. The answer is held until they really stop.
    var specBasis: String?                 // the words the early answer was started on
    var specHeld: (s: Suggestion, id: Int)?
    var specTimer: Task<Void, Never>?
    var confirmedAt: Date?

    /// A new line never replaces one the rep has had less than this long to read.
    let hold: TimeInterval = 4
    /// A line stays until the rep has said it (about 4 words heard from the rep),
    /// or this many seconds pass. New lines wait, so nothing changes mid-read.
    let lockSeconds: TimeInterval = 15
    var repWordsSinceShown = 0
    var repWordsInCall = 0

    /// True while the line on screen is new and the rep hasn't said it yet.
    var lineIsFresh: Bool {
        (kind == .reply || kind == .opener) && !suggestion.say.isEmpty
            && repWordsSinceShown < 4 && Date().timeIntervalSince(shownAt) < lockSeconds
    }

    var active = false

    /// Only the visible coach screen reacts to calls (not while the audio check runs).
    func activate(_ on: Bool) {
        active = on
        BugReporter.context = { [weak self] in self?.debugSummary() ?? "" }
        if on { onAppear() } else if status != .ready { nextCall() }
    }

    func onAppear() {
        // Redraw the coach when the call list changes (it lives in its own object).
        if listWatcher == nil {
            listWatcher = callList.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            leadsWatcher = leads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            // A new lead loaded between calls: write its opener and voicemail.
            leadDetailsWatcher = leads.$details.sink { [weak self] details in
                guard let details else { return }
                Task { @MainActor in
                    guard let self, self.status == .ready, details.id != self.appliedLeadID else { return }
                    self.applyLead()
                }
            }
            Task { await leads.start() }
        }
        if suggestion.say.isEmpty, !thinking { prepareOpener() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Call lifecycle

    /// Points the coach at the record open in Chrome right now: name, opener, voicemail,
    /// follow-ups and status all for that one person. Called every second between calls,
    /// and always right before dialing, so nothing from the last person carries over.
    var lastSyncedKey: String?

    var autoHangingUp = false
    var autoHungUpThisCall = false
    /// The app hung up a 1st-try recording: redial after 1 second instead of 3.
    var redialRightAway = false

    // MARK: Auto next

    /// Seconds left before the app moves to the next lead by itself. Nil = not counting.
    @Published var autoNextIn: Int?
    var autoNextTask: Task<Void, Never>?

    /// Who's next, for the countdown banner.
    var nextLeadName: String? {
        if leads.isActive { return leads.nextRow?.name }
        if case .ready(let name, _, _) = callList.state { return name }
        return nil
    }

    var endedAt = Date.distantPast

    /// After a call ends while Chrome still holds the mic, don't treat that as a new call.
    var waitingForNewCall = false
    var callStartedAt = Date.distantPast
    var heardCallAudio = false
    var retargets = 0

    // Aircall says when the call is over. Asked every 2 seconds during a call; two "no call"
    // answers in a row end it (so one slow answer can't end a live call).
    var aircallTicks = 0
    var aircallSaysOver = 0
    var aircallSawCall = false
    var aircallCheck: Task<Void, Never>?

    var hangUpGen = 0

    // MARK: Audio and transcription

    var directAudio = false
    var directCheck: Task<Void, Never>?

    var pendingStop: Task<Void, Never>?
    /// The record Id the ready-made voicemail is for (matches the follow-up card's key).
    var voicemailKey: String?
    var lastVoicemailError: String?
    var lastVoicemailTry = Date.distantPast
    /// Who the ready-made voicemail was written for, and whether it used their Salesforce page.
    var voicemailFor: String?
    var voicemailUsedDetails = false
    /// The page's details were read (or tried) for the person on screen.
    var detailsTried = false
    /// Who Claude's personal opener on screen is for.
    var personalOpenerFor: String?
    var instantOpenerID = -1
    /// Why a call didn't start. Shown right above the Call button and never wiped by a new line.
    @Published var callMessage: String?
    /// Everyone due today on this list has been called: time to switch to the next list.
    @Published var listDone = false

    /// Who the countdown is for.
    @Published var autoNextName: String?
    /// "Getting Burcin's script ready..." while the app waits to dial.
    @Published var gettingReady: String?
    /// What the Call button is waiting for, in a sentence (shown above the buttons).
    @Published var gettingReadyDetail: String?
    var readyTask: Task<Void, Never>?
    var detailsPending = false
    /// The record Next just opened, until its page is showing.
    var openingID: String?
    var openingSince = Date.distantPast

    /// Everything the prospect side has said this call (finished words only).
    var prospectSoFar: String {
        turns.filter { $0.speaker == .prospect }.map(\.text).joined(separator: " ")
    }

    /// After the rep asks a question: 6 s of silence shows "Still with me?".
    var stillWithMeTask: Task<Void, Never>?

    /// The carrier says the number doesn't work: show it, and skip voicemail and follow-ups.
    var badNumberThisCall = false
    var phoneTreeThisCall = false

    /// In a phone menu right now (until a person answers or a mailbox beep is coming).
    var phoneTreeActive = false
    var phoneTreeTask: Task<Void, Never>?

    /// The rep clicked "Press 3": sends those keys into the call (the in-app Aircall phone only).
    @Published var keysMessage: String?
    var followUpThisCall = false
    var followUpWatchdog: Task<Void, Never>?

    /// The company line from the Salesforce page, if it shows one (helps LinkedIn find the right person).
    var recordCompany: String? {
        guard let lines = recordDetails?.components(separatedBy: "\n") else { return nil }
        for (i, line) in lines.enumerated() where ["Company", "Account Name"].contains(line.trimmingCharacters(in: .whitespaces)) {
            if i + 1 < lines.count { return lines[i + 1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // MARK: Claude

    /// Everything the rep wrote in the campaign: each section, then the pasted script.
    var campaignText: String {
        (Campaign.sections.map { campaign[keyPath: $0.key] } + [campaign.pastedScript]).joined(separator: "\n\n")
    }

    /// "Clarity" from the campaign's company description.
    var shortCompany: String {
        let c = campaign.company
        if c.localizedCaseInsensitiveContains("Clarity") { return "Clarity" }
        let first = c.components(separatedBy: CharacterSet(charactersIn: ",.;:")).first ?? ""
        let words = first.split(separator: " ").prefix(3).joined(separator: " ")
        return words.isEmpty ? "Clarity" : words
    }

}
