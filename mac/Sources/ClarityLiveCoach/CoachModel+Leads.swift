import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Who is up next: the Salesforce record on screen, its status, Next/Back, and the dial gate.
extension CoachModel {
    /// Notices which Contact or Lead is on screen and loads its status.
    func refreshRelationship() {
        let id: String? = leads.isActive ? leads.details?.id : SalesforceChrome.url().flatMap(CallList.recordID)
        let usable = id.flatMap { Salesforce.objectFor(id: $0) == nil ? nil : $0 }
        // No record on screen (LinkedIn opened, a list page, Chrome busy): keep the last person.
        // Only a different person's record switches the status card.
        guard usable != nil, usable != statusRecordID else { return }
        statusRecordID = usable
        recordStatus = nil
        statusMessage = nil
        guard let usable else { return }
        if RemovedList.contains(usable) || DialHistory.isMaxed(usable) { skipRemoved(usable); return }
        guard Salesforce.isConnected else { return }
        // Their time zone, for the time zone filter (a no-op when the list already loaded it).
        if let object = Salesforce.objectFor(id: usable) {
            Task { await TimeZoneFilter.load(ids: [usable], object: object) }
        }
        Task { [weak self] in
            // Only act on a real answer from Salesforce (an error is not "blank").
            let loaded: String?
            do { loaded = try await Salesforce.status(of: usable) } catch { return }
            guard let self, self.statusRecordID == usable else { return }
            let value = loaded?.trimmingCharacters(in: .whitespaces)
            if (value ?? "").isEmpty {
                // A Contact with no Relationship Status yet: set it to No Relationship.
                if Salesforce.objectFor(id: usable) == "Contact" {
                    self.recordStatus = "No Relationship"
                    do {
                        try await Salesforce.setStatus(of: usable, to: "No Relationship")
                        ActivityLog.add("Status: blank, saved No Relationship for \(self.calling ?? usable)")
                    } catch {
                        if self.statusRecordID == usable { self.recordStatus = nil }
                        ActivityLog.problem("Couldn't set No Relationship: \(error.localizedDescription)")
                    }
                }
                return
            }
            self.recordStatus = value
            if let value, Salesforce.removedStatuses.contains(value) {
                RemovedList.add(usable)
                self.skipRemoved(usable)
            }
        }
    }

    /// Someone already marked Not Quality Prospect, Negative or Unqualified came up between calls:
    /// move on to the next person (without calling). Only for people on the call list, so opening
    /// a record by hand to look at it doesn't jump away.
    func skipRemoved(_ id: String) {
        guard status == .ready, !dialing else { return }
        let onList = leads.isActive
            ? leads.current.map { String($0.id.prefix(15)) == String(id.prefix(15)) } ?? false
            : callList.records.contains { String($0.id.prefix(15)) == String(id.prefix(15)) }
        guard onList else { return }
        statusMessage = nil
        problem = "Skipped someone marked off your list."
        nextLead(dial: false)
    }

    /// The Save button: writes the status to Salesforce.
    /// "Not Quality Prospect", "Negative" and "Unqualified" also take them off the call list.
    func saveStatus(_ value: String, unqualifiedReason: String? = nil) {
        guard let id = statusRecordID, !savingStatus else { return }
        guard Salesforce.isConnected else {
            statusMessage = "Sign in to Salesforce first: gear menu > Setup > Salesforce."
            return
        }
        savingStatusFor = id
        statusMessage = nil
        ActivityLog.add("Status: saving \(value) for \(calling ?? id)")
        Task { [weak self] in
            do {
                // Never hang: give up after 15 seconds.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await Salesforce.setStatus(of: id, to: value, unqualifiedReason: unqualifiedReason) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(15))
                        throw Salesforce.SFError(message: "Salesforce didn't answer in 15 seconds. Try Save again.")
                    }
                    try await group.next()
                    group.cancelAll()
                }
                guard let self else { return }
                if self.savingStatusFor == id { self.savingStatusFor = nil }
                ActivityLog.add("Status: saved \(value)")
                // Taken off the list even if the rep already moved on.
                if Salesforce.removedStatuses.contains(value) { RemovedList.add(id) } else { RemovedList.remove(id) }
                guard self.statusRecordID == id else { self.callList.refreshUpNext(); return }
                self.recordStatus = value
                if Salesforce.removedStatuses.contains(value) {
                    RemovedList.add(id)
                    self.statusMessage = "Saved. Taken off your list."
                    // Between calls: on to the next person right away (and call them, if auto-dial is on).
                    // During a call: the app moves on by itself when the call ends (see endCall).
                    if self.status == .ready {
                        if self.autoNextTask != nil, self.currentAttemptKey.map({ $0.prefix(15) == id.prefix(15) }) == true {
                            // The redial countdown was running for them: stop it and go to the next person.
                            ActivityLog.add("Redial cancelled: marked \(value)")
                            self.startNextSequence()
                        } else if self.openingID == nil, self.autoNextIn == nil {
                            // Still getting their call ready: stop that, they're off the list.
                            self.readyTask?.cancel()
                            self.gettingReady = nil
                            self.gettingReadyDetail = nil
                            ActivityLog.add("Marked \(value): on to the next person")
                            self.waitingForText = false
                            self.startNextSequence()
                        }
                    }
                } else {
                    RemovedList.remove(id)
                    self.statusMessage = "Saved."
                }
                self.callList.refreshUpNext()
            } catch {
                ActivityLog.problem("Status: save failed: \(error.localizedDescription)")
                guard let self else { return }
                if self.savingStatusFor == id { self.savingStatusFor = nil }
                if self.statusRecordID == id { self.statusMessage = error.localizedDescription }
            }
        }
    }

    /// Points the coach at the lead on screen: name, details, opener, voicemail.
    func applyLead() {
        guard let d = leads.details else { return }
        problem = nil
        if d.id != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        appliedLeadID = d.id
        calling = "\(d.object) \"\(d.name)\""
        recordDetails = d.promptText
        prepareOpener()
        prepareVoicemail()
        startFollowUp()
        refreshRelationship()
    }

    /// Calls the lead from the Aircall desktop app.
    func dial(_ number: String? = nil) {
        // Mobile first, then Phone. Neither: skip them and take them off the list.
        if status == .ready, !dialing, number == nil, let d = leads.details, !d.doNotCall, d.callNumber == nil {
            ActivityLog.add("No Mobile or Phone for \(d.name): skipping and removing from the list")
            RemovedList.add(d.id)
            problem = "No phone number. Removed from your list, on to the next person."
            nextLead()
            return
        }
        guard status == .ready, !dialing, let d = leads.details, !d.doNotCall,
              let phone = number ?? d.callNumber else { return }
        guard planAllowsCall(d.id) else { return }
        dialing = true
        dialError = nil
        Task { [weak self] in
            do {
                try await Aircall.startCall(to: phone)
                guard let self else { return }
                self.dialing = false
                self.leads.markCurrentCalled()
                if self.status == .ready { self.pendingDialSince = Date() } // the call may already be live
            } catch {
                self?.dialing = false
                self?.dialError = error.localizedDescription
            }
        }
    }

    /// Ends the call (if any) and opens the next lead on the rep's list. The coach then
    /// picks up the new record and writes a fresh opener and voicemail for it.
    func previousLead() {
        cancelAutoNext()
        if leads.isActive {
            if status != .ready { endCall() }
            Task { await leads.back() }
            return
        }
        if status != .ready { nextCall() }
        if callList.openPrevious() {
            suggestion = Suggestion()
            calling = nil
            tabTicks = 1
        }
    }

    /// - Parameter dial: false = just show the next person, don't call yet.
    func nextLead(dial shouldDial: Bool = true) {
        cancelAutoNext()
        let dialNow = shouldDial && (Prefs.autoDial)
        if leads.isActive {
            if status != .ready { endCall() }
            Task { [weak self] in
                guard let self else { return }
                var moved = await self.leads.next()
                if !moved {
                    // End of the list: reload it from Salesforce to pick up new people.
                    await self.leads.reload(keepCurrent: false)
                    moved = self.leads.current.map { CalledToday.isCallable($0.id) } ?? false
                }
                guard moved else {
                    self.listDone = true // the banner says why and offers the next list
                    ActivityLog.add("List done for today: \(self.leads.selected?.label ?? "Salesforce list")")
                    return
                }
                self.listDone = false
                // Skip Do Not Call records and records with no mobile number (up to 20 in a row).
                var skipped = 0
                while self.leads.details.map({ $0.doNotCall || $0.callNumber == nil }) == true, skipped < 20,
                      await self.leads.next() { skipped += 1 }
                // "Next calls right away" (on by default): dial as soon as the lead is loaded.
                if dialNow, self.leads.details?.doNotCall == false {
                    self.applyLead()
                    self.dial()
                } else {
                    self.applyLead()
                }
            }
            return
        }
        if status != .ready { endCall() }
        if openNextInChrome() {
            if dialNow { dialFromSalesforcePage(expecting: callList.lastOpenedID) }
            return
        }
        // Ran out of people the app can see: scroll the Salesforce list to load more, then try again.
        Task { [weak self] in
            guard let self else { return }
            self.gettingReady = "Loading more people..."
            let more = await self.callList.loadMore()
            self.gettingReady = nil
            ActivityLog.add("Next: loaded more rows from the list (\(more ? "found more" : "none"))")
            if more, self.openNextInChrome(), dialNow {
                self.dialFromSalesforcePage(expecting: self.callList.lastOpenedID)
            } else if !more {
                self.listDone = true // the banner offers the next campaign's list
                ActivityLog.add("List done for today: \(self.campaign.name)")
            }
        }
    }

    /// Opens the next person in the Salesforce tab and points the coach at them right away.
    func openNextInChrome() -> Bool {
        problem = nil
        guard callList.openNext() else {
            ActivityLog.add("Next: couldn't open the next person (\(callList.message ?? "no reason"))")
            return false
        }
        callMessage = nil
        listDone = false
        let upcoming = callList.records.first { $0.id == callList.lastOpenedID }?.name
        // Show their opener now, before the page loads and before the phone rings.
        let kind = callList.lastOpenedID.map { $0.hasPrefix("003") ? "Contact" : "Lead" } ?? "Lead"
        meet(upcoming.map { "\(kind) \"\($0)\"" })
        openingID = callList.lastOpenedID
        openingSince = Date()
        ActivityLog.add("Next: opened \(calling ?? "?")")
        prepareOpener()
        detailsPending = true // read their page once it loads, for a more personal line
        tabTicks = 1  // read the page on the very next tick
        return true
    }

    /// The text was sent (or skipped): open the next person, wait until their opener,
    /// voicemail and follow-ups are all for them, then count down 5 seconds and dial.
    /// With Auto-dial off, it only opens the next person.
    func startNextSequence() {
        cancelAutoNext()
        guard status == .ready else { return }
        followUp = nil // the last person's follow-ups are done
        if leads.isActive {
            // Nobody left: Next reloads the list, or says the list is done for today.
            if autoDial, nextLeadName != nil { startAutoNext() } else { nextLead(dial: false) }
            return
        }
        guard openNextInChrome() else {
            nextLead(dial: autoDial) // loads more of the list, or says the list is done
            return
        }
        if autoDial { dialFromSalesforcePage(expecting: callList.lastOpenedID, countdown: 3) }
    }

    /// Only call people in this time zone (nil = everyone). Both call lists skip the rest.
    func setTimeZoneFilter(_ zone: CallZone?) {
        guard zone != TimeZoneFilter.selected else { return }
        TimeZoneFilter.selected = zone
        ActivityLog.add("Time zone filter: \(zone?.label ?? "all time zones")")
        cancelAutoNext()
        listDone = false
        callMessage = nil
        callList.refreshUpNext()
        objectWillChange.send()
        Task { await leads.timeZoneChanged() }
    }

    /// Call East Coast leads first (then Central, Mountain, Pacific). Works on both call lists.
    func setEastCoastFirst(_ on: Bool) {
        guard on != TimeZoneFilter.eastCoastFirst else { return }
        TimeZoneFilter.eastCoastFirst = on
        ActivityLog.add("East Coast first: \(on ? "on" : "off")")
        cancelAutoNext()
        leads.reorder()
        callList.refreshUpNext()
        objectWillChange.send()
    }

    /// Follows the call plan (days 1, 2, 5, 8, 16; 2 dials a day). If this person shouldn't be
    /// called right now, says why and returns false. Clicking Call again within 15 seconds calls anyway
    /// (for someone who asked for a call back).
    func planAllowsCall(_ id: String?) -> Bool {
        guard let id, Salesforce.objectFor(id: id) != nil, let why = Cadence.whyNotNow(id) else { return true }
        if callAnywayID == id, Date() < callAnywayUntil {
            callAnywayID = nil
            ActivityLog.add("Plan: called \(calling ?? id) anyway (\(why))")
            return true
        }
        callAnywayID = id
        callAnywayUntil = Date().addingTimeInterval(15)
        callMessage = "\(why) Click Call again to call anyway."
        ActivityLog.add("Plan: didn't call \(calling ?? id). \(why)")
        return false
    }

    /// Who the current lead is, for counting tries.
    func recordKey() -> String? {
        if leads.isActive { return leads.details?.id }
        return SalesforceChrome.url().flatMap(CallList.recordID) ?? calling
    }

    /// Calls the same person again right away.
    func redial() {
        guard status == .ready, let key = currentAttemptKey, !RemovedList.contains(key) else { return }
        cancelAutoNext()
        if leads.isActive {
            dial() // checks the plan
        } else if !dialing, planAllowsCall(key), !callFromPage() {
            problem = "No phone number on this Salesforce page. Click Next."
        }
    }

    /// The Call button for the lead open in Salesforce.
    func callOpenLead() {
        cancelAutoNext()
        guard status == .ready, !dialing, gettingReady == nil else { return } // busy, not a missing number
        callMessage = nil
        guard planAllowsCall(SalesforceChrome.url().flatMap(CallList.recordID)) else { return }
        gettingReady = "Getting ready..."
        ActivityLog.add("Call button: \(calling ?? "no record")")
        callWhenReady { [weak self] in self?.callMessage = "No phone number on this Salesforce page. Click Next." }
    }

    /// Everything on screen is for the person open in Salesforce: name, page details,
    /// voicemail and follow-ups (written from their page), and Claude's opener for them.
    func readyToDial(waited: TimeInterval) -> Bool {
        guard let calling, SalesforceTab.currentRecord(live: true) == calling else { return false }
        let detailsOK = detailsTried
        let voicemailOK = voicemailScript != nil && voicemailFor == calling
            && (voicemailUsedDetails || recordDetails == nil || waited > 8)
        // Claude's personal opener; after 10 seconds the instant one (already for them) is enough.
        let openerOK = personalOpenerFor == calling || waited > 10
        return detailsOK && voicemailOK && openerOK
    }

    /// The one thing the app is still waiting for, in a few words (for the Call button).
    func waitingFor() -> String {
        guard let calling else { return "an open Salesforce record" }
        if SalesforceTab.currentRecord() != calling { return "the Salesforce page" }
        if !detailsTried { return "their page details" }
        if !(voicemailScript != nil && voicemailFor == calling) { return "their voicemail" }
        return "their opener"
    }

    /// What's still missing, in plain words, when the app won't dial.
    func readinessGap() -> String {
        guard let calling else { return "no Salesforce record is open in Chrome" }
        if SalesforceTab.currentRecord() != calling { return "the Salesforce page doesn't match \(Screener.firstName(calling) ?? "this person")" }
        if !detailsTried { return "couldn't read their Salesforce page" }
        if !(voicemailScript != nil && voicemailFor == calling) {
            return "their voicemail and follow-ups weren't written" + (lastVoicemailError.map { " (Claude said: \($0))" } ?? "")
        }
        return "their opener wasn't ready"
    }

    /// Dials only once the script and follow-ups are for this exact person. Gives up after 25 s.
    func callWhenReady(countdown: Int = 0, onFail: @escaping () -> Void = {}) {
        readyTask?.cancel()
        readyTask = Task { [weak self] in
            let start = Date()
            while let self, !Task.isCancelled, self.status == .ready {
                self.syncRecord()
                let waited = Date().timeIntervalSince(start)
                // No voicemail for this person and nothing writing one: try again.
                let haveVoicemail = self.voicemailScript != nil && self.voicemailFor == self.calling
                if !haveVoicemail, self.voicemailTask == nil, self.calling != nil, self.detailsTried || waited > 4,
                   Date().timeIntervalSince(self.lastVoicemailTry) > 3 { self.prepareVoicemail() }
                // Claude still hasn't written it: use the ready-made one with their name.
                if !haveVoicemail, waited > 12, let who = self.calling {
                    self.voicemailTask?.cancel()
                    self.voicemailTask = nil
                    self.voicemailScript = self.instantVoicemail(for: who)
                    self.voicemailFor = who
                    self.voicemailKey = self.recordKey()
                    self.voicemailUsedDetails = true
                    ActivityLog.problem("Used the ready-made voicemail for \(who). Claude: \(self.lastVoicemailError ?? "no answer in 12 s")")
                }
                if self.readyToDial(waited: waited) {
                    self.gettingReady = nil
                    self.gettingReadyDetail = nil
                    self.lastWaitingFor = ""
                    ActivityLog.add("Gate: ready for \(self.calling ?? "?") after \(Int(waited)) s")
                    // Everything matches: "Calling Burcin Sonmezer in 5", with a Wait button.
                    if countdown > 0 {
                        let who = self.calling
                        self.autoNextName = Screener.fullName(who)
                        for left in stride(from: countdown, through: 1, by: -1) {
                            self.autoNextIn = left
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled, self.status == .ready else { self.autoNextIn = nil; return }
                        }
                        self.autoNextIn = nil
                        // Last check: still the same person, still all theirs.
                        guard self.calling == who, self.readyToDial(waited: 99) else {
                            self.callMessage = "The Salesforce page changed during the countdown. Click Call when ready."
                            return
                        }
                    }
                    if !self.callFromPage() { onFail() }
                    return
                }
                if waited > 25 {
                    self.gettingReady = nil
                    self.gettingReadyDetail = nil
                    self.callMessage = "Didn't call: \(self.readinessGap()). Click Call to try again."
                    ActivityLog.problem("Gate: gave up after 25 s. \(self.readinessGap())")
                    self.lastWaitingFor = ""
                    return
                }
                let name = Screener.firstName(self.calling) ?? "the next person"
                let missing = self.waitingFor()
                self.gettingReady = "Getting ready..."
                self.gettingReadyDetail = "Getting \(name) ready: waiting for \(missing)."
                if missing != self.lastWaitingFor {
                    self.lastWaitingFor = missing
                    ActivityLog.add("Gate: \(self.calling ?? "nobody") waiting for \(missing) (page shows \(SalesforceTab.currentRecord() ?? "nothing"))")
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.gettingReady = nil
            self?.gettingReadyDetail = nil
        }
    }

    /// Calls the Mobile number on the open Salesforce page (or Phone, if there's no Mobile), right
    /// from the app (through Aircall). Only if Aircall calling isn't set up does it click the number
    /// in Salesforce. Returns false when the page has neither.
    @discardableResult
    func callFromPage() -> Bool {
        guard status == .ready, !dialing else { return false }
        syncRecord() // make sure the script and voicemail are for this person
        // The Aircall phone inside the coach (or the desktop app): dial through the API.
        if AircallPhone.isOn || Aircall.canPlaceCalls {
            guard let mobile = SalesforceChrome.dialNumber() else {
                ActivityLog.add("Dial: no Mobile or Phone found on the page for \(calling ?? "?")")
                return false
            }
            ActivityLog.add("Dial: \(calling ?? "?") at \(mobile)")
            dialing = true
            dialError = nil
            Task { [weak self] in
                do {
                    try await Aircall.startCall(to: mobile)
                    guard let self else { return }
                    self.dialing = false
                    self.callList.markCurrentCalled()
                    if self.status == .ready { self.pendingDialSince = Date() } // the call may already be live
                } catch {
                    self?.dialing = false
                    self?.callMessage = "Aircall didn't start the call: \(error.localizedDescription)"
                    ActivityLog.problem("Dial failed: \(error.localizedDescription)")
                }
            }
            return true
        }
        guard SalesforceChrome.clickToDial() else { return false }
        waitingForNewCall = false // a new call, even if Chrome still holds the mic
        return true
    }

    /// Waits for the lead's Salesforce page to load, then clicks its Mobile number (Aircall in Salesforce dials).
    func dialFromSalesforcePage(expecting id: String?, countdown: Int = 0) {
        readyTask?.cancel()
        // Kept in readyTask, so Wait, Next and Call cancel it like everything else.
        readyTask = Task { [weak self] in
            var pageOpened = id == nil
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.status == .ready else { return }
                if let id, SalesforceChrome.url(live: true).flatMap(CallList.recordID) != id { continue } // not loaded yet
                pageOpened = true
                if SalesforceChrome.dialNumber() != nil {
                    // Page loaded and has a Mobile or Phone: dial once their script and follow-ups are ready.
                    self.noMobileSkips = 0
                    self.callWhenReady(countdown: countdown) { [weak self] in self?.callMessage = "No phone number on this Salesforce page. Click Next." }
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            guard pageOpened else {
                // The page never opened: don't skip anyone, just say so.
                self.callMessage = "Their Salesforce page didn't open. Click Call when it's showing."
                ActivityLog.problem("Next: page for \(id ?? "?") didn't open in 8 s")
                return
            }
            // No Mobile or Phone: nothing to call. Skip to the next person (up to 20 in a row).
            ActivityLog.add("Next: no Mobile or Phone for \(self.calling ?? "?"), skipping and removing from the list")
            if let key = id ?? self.recordKey() { RemovedList.add(key); self.callList.refreshUpNext() }
            self.noMobileSkips += 1
            if self.noMobileSkips <= 20 {
                self.problem = "No phone number. Skipped to the next person."
                self.nextLead()
            } else {
                self.noMobileSkips = 0
                self.problem = "20 people in a row had no phone number. Check the Mobile and Phone fields are on the Salesforce page."
            }
        }
    }

    func syncRecord() {
        guard !leads.isActive else { return }
        // Just opened someone: ignore the old page until theirs shows, so nothing flips back.
        // (The address changes before the tab title does, so also wait for the title, up to 3 s.)
        if let waitingFor = openingID {
            let age = Date().timeIntervalSince(openingSince)
            // Wait for their page (up to 6 s), then for the title (up to 3 s). Never longer.
            if age < 6, SalesforceChrome.url().flatMap(CallList.recordID).map({ $0.prefix(15) }) != waitingFor.prefix(15) { return }
            if age < 3, SalesforceTab.currentRecord() != calling { return }
            openingID = nil
        }
        let record = SalesforceTab.currentRecord()
        refreshRelationship()
        // Nothing on screen (LinkedIn opened, a list page): keep everything for the last person,
        // so the status, LinkedIn and text cards stay up. Only a different person switches them.
        guard record != nil else { return }
        // Two leads can share a name ("Unknown Unknown"): a different Salesforce record ID is a new person too.
        let pageKey = recordKey()
        guard record != calling || detailsPending || pageKey != lastSyncedKey else { return }
        lastSyncedKey = pageKey
        if record != calling {
            ActivityLog.add("Record on screen: \(record ?? "none") (was \(calling ?? "none"))")
            callMessage = nil // a new person: the last person's message no longer applies
        }
        detailsPending = false
        meet(record)
        if recordKey() != currentAttemptKey { currentAttemptKey = nil; lastCallAnswered = true }
        prepareOpener()
        // The voicemail is written once, after their page is read (below), not twice.
        voicemailTask?.cancel()
        voicemailTask = nil
        voicemailScript = nil
        // Their text and LinkedIn card is always up while their record is open.
        startFollowUp()
        // Salesforce fills in the page after the title changes: read the details a moment later.
        detailsTask?.cancel()
        let pageID = SalesforceChrome.url().flatMap(CallList.recordID)
        detailsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled, self.calling == record, record != nil,
                  SalesforceChrome.url(live: true).flatMap(CallList.recordID) == pageID else { return }
            self.recordDetails = SalesforceTab.pageText()
            self.detailsTried = true
            // Fill in the card's phone and LinkedIn link now that the page is loaded.
            if var f = self.followUp, f.key == self.recordKey() {
                if Salesforce.isPlaceholderName(f.prospect ?? ""), let company = self.recordCompany, !company.isEmpty { f.prospect = company }
                if f.phone.isEmpty { f.phone = Aircall.phone(in: self.recordDetails) ?? SalesforceChrome.mobileNumber() ?? "" }
                if f.linkedinURL == nil { f.linkedinURL = Self.linkedInProfile(details: self.recordDetails) }
                self.followUp = f
                self.applyPlan()
            }
            ActivityLog.add("Page details for \(record ?? "?"): \(self.recordDetails == nil ? "couldn't read (Chrome setting?)" : "read")")
            if self.recordDetails != nil, self.status == .ready { self.prepareOpener() }
            self.prepareVoicemail()
        }
    }
}
