import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Phone menus and bad numbers.
extension CoachModel {
    /// A phone menu answered: disqualify (Not Quality Prospect / Unqualified), hang up in the
    /// in-app phone, and move on. No voicemail, text or redial. If the hang-up button can't be
    /// found, the rep hangs up and the next call still starts by itself.
    func markPhoneTree() {
        badNumberThisCall = true
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { markNotQualityProspect(key, reason: "phone tree") }
        seq += 1
        show(Suggestion(say: "Phone tree. Hanging up. The next call starts by itself.", cue: "Disqualified: phone menus aren't worth working.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
        guard AircallPhone.isOn else { return }
        Task { [weak self] in
            guard let self, self.status == .live else { return }
            guard await AircallPhone.shared.hangUp() else {
                self.show(Suggestion(say: "Phone tree. Hang up. The next call starts by itself.", cue: "Disqualified.",
                                     stage: "Exit", sayComplete: true), id: self.seq, kind: .reply)
                return
            }
            // End on our side once Aircall says the line is free (up to 5 s); otherwise Aircall's own end does it.
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                if await Aircall.lineIsOnCall() == false, self.status == .live { self.endCall(); return }
            }
        }
    }

    /// A phone menu answered. Show the quick ways through right away, then have Opus listen to the
    /// whole menu and pick the best route to the owner. No voicemail card while the menu plays.
    func enterPhoneTree() {
        phoneTreeActive = true
        voicemailActive = false
        sawVoicemail = false
        showPhoneTreeTips()
        askPhoneTree()
    }

    /// Opus 5.5 reads everything the menu has said so far and names the highest-leverage keys to
    /// press to reach the owner. Re-asked each time the menu finishes a sentence (after a short pause,
    /// so a new option isn't missed). If a live person is now talking, it says what to say to them.
    func askPhoneTree() {
        guard let apiKey = Keychain.read(.anthropic) else { return }
        phoneTreeTask?.cancel()
        let menu = prospectSoFar
        let who = calling
        let user = CoachPrompt.phoneTree(menu: menu, calling: calling, details: recordDetails,
                                         repSaid: turns.filter { $0.speaker == .rep }.map(\.text).joined(separator: " "))
        let system = self.system
        phoneTreeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
            self.seq += 1
            let id = self.seq
            self.thinking = true
            var text = ""
            do {
                try await CoachSpeed.best.client(apiKey: apiKey).stream(system: system, user: user) { text = $0 }
            } catch {
                if !Task.isCancelled { ActivityLog.problem("Phone tree advice failed: \(error.localizedDescription)") }
                if self.seq == id { self.thinking = false }
                return
            }
            if self.seq == id { self.thinking = false }
            guard !Task.isCancelled, self.phoneTreeActive, self.calling == who else { return }
            let human = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("HUMAN")
            var s = Suggestion.parse(text)
            guard !s.say.isEmpty else { return }
            s.sayComplete = true
            if human {
                // A person picked up (receptionist or the owner): back to normal coaching.
                self.phoneTreeActive = false
                s.stage = s.stage.isEmpty ? "Gatekeeper" : s.stage
                ActivityLog.add("Phone tree: a person answered for \(who ?? "?")")
            } else {
                s.stage = "Phone tree"
                ActivityLog.add("Phone tree route for \(who ?? "?"): \(s.say)")
            }
            self.show(s, id: id, kind: .reply)
        }
    }

    func pressKeys(_ keys: String) {
        guard status == .live, !keys.isEmpty else { return }
        keysMessage = "Pressing \(keys)..."
        Task { [weak self] in
            let ok = await AircallPhone.shared.sendDigits(keys)
            guard let self else { return }
            ActivityLog.add("Phone tree: pressed \(keys) (\(ok ? "sent" : "didn't go through"))")
            self.keysMessage = ok ? "Pressed \(keys)." : "Couldn't press keys from the app. Use the Aircall keypad."
        }
    }

    /// A phone menu answered: how to get through to the person. Press 0 for an operator, or dial
    /// by name with the first letters of their last name as keypad digits.
    func showPhoneTreeTips() {
        phoneTreeThisCall = true
        coachTask?.cancel()
        thinking = false
        let full = Screener.fullName(calling)
        let last = full?.split(separator: " ").last.map(String.init) ?? ""
        let keys: [Character: Character] = Dictionary(uniqueKeysWithValues: Array(zip("abcdefghijklmnopqrstuvwxyz",
                                                                                        "22233344455566677778889999")))
        let digits = String(last.lowercased().compactMap { keys[$0] }.prefix(4))
        let byName = digits.isEmpty ? "" : " Dial by name: \(digits) (\(last.prefix(4)))."
        ActivityLog.add("Phone tree for \(calling ?? "?"): showing how to get through")
        seq += 1
        var tips = Suggestion(say: "Phone tree. Press 0 for the operator.\(byName)",
                              cue: "Listening to the menu for a better route. When a person answers: \"Hi, could you put me through to \(full ?? "them")?\"",
                              stage: "Phone tree", sayComplete: true)
        tips.keys = "0"
        show(tips, id: seq, kind: .reply)
    }

    func markBadNumber() {
        badNumberThisCall = true
        coachTask?.cancel()
        thinking = false
        voicemailActive = false
        sawVoicemail = false
        followUp = nil
        if let key = currentAttemptKey { markNotQualityProspect(key, reason: "carrier says the number can't take calls") }
        seq += 1
        show(Suggestion(say: "Bad number. Hang up. The next call starts by itself.", cue: "The carrier says this number doesn't work.",
                        stage: "Exit", sayComplete: true), id: seq, kind: .reply)
    }

    /// Bad number: off the call list for good (in the app), and marked in Salesforce as
    /// Not Quality Prospect (Contacts) or Unqualified (Leads). Nothing is deleted in Salesforce.
    func markNotQualityProspect(_ id: String, reason: String) {
        DialHistory.markBadNumber(id)
        RemovedList.add(id)
        callList.refreshUpNext()
        guard let object = Salesforce.objectFor(id: id) else { return }
        let value = object == "Lead" ? "Unqualified" : "Not Quality Prospect"
        ActivityLog.add("Off the list (\(reason)): \(calling ?? id), marking \(value)")
        guard Salesforce.isConnected else { return }
        Task { [weak self] in
            do {
                try await Salesforce.setStatus(of: id, to: value, unqualifiedReason: "Non-Responsive",
                                               note: reason == "phone tree" ? "Phone tree" : "Bad number (\(reason))")
                ActivityLog.add("Status: saved \(value) (bad number)")
                if self?.statusRecordID == id { self?.recordStatus = value }
            } catch {
                ActivityLog.problem("Couldn't mark the bad number in Salesforce: \(error.localizedDescription)")
            }
        }
    }
}
