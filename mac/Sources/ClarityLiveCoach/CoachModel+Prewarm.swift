import Foundation

/// Gets the NEXT person ready while the current call is still ringing: reads their record from
/// Salesforce and has Claude write their voicemail, text and LinkedIn notes. When the rep moves
/// on, those are already there, so the wait before the next dial is a couple of seconds, not ten.
/// Nothing on screen changes and Chrome isn't touched: it's all in the background.
extension CoachModel {
    func prewarmNext() {
        guard Salesforce.isConnected, let apiKey = Keychain.read(.anthropic) else { return }
        let nextID: String? = leads.isActive ? leads.nextRow?.id : callList.upNext()?.record.id
        guard let id = nextID, let object = Salesforce.objectFor(id: id) else { return }
        let key = String(id.prefix(15))
        if let ready = prewarmed[key], Date().timeIntervalSince(ready.at) < 1800 { return }
        guard prewarmingKey != key else { return }
        prewarmingKey = key
        let system = self.system
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            guard let d = try? await Salesforce.details(id: id, object: object) else {
                if self?.prewarmingKey == key { self?.prewarmingKey = nil }
                return
            }
            let phone = d.phone?.trimmingCharacters(in: .whitespaces)
            KnownNumbers.set(id, mobile: d.textNumber, phone: (phone?.isEmpty ?? true) ? nil : phone)
            let calling = "\(d.object) \"\(d.name)\""
            let user = CoachPrompt.voicemail(calling: calling, details: d.promptText,
                                             earlierTexts: DialHistory.sentTexts(id),
                                             earlierMessages: DialHistory.sentLinkedInMessages(id),
                                             history: DialHistory.historySummary(id),
                                             localLunch: LocalLunch.isLocal(city: d.city, state: d.state, phones: [d.mobile, d.phone]))
            let client = CoachSpeed.fastest.client(apiKey: apiKey)
            var text = ""
            let wrote: Bool
            do {
                try await client.stream(system: system, user: user) { text = $0 }
                wrote = true
            } catch {
                wrote = false
            }
            guard let self else { return }
            if self.prewarmingKey == key { self.prewarmingKey = nil }
            var s = Suggestion.parse(text)
            s.sayComplete = true
            s.stage = "Voicemail"
            guard wrote, !Task.isCancelled, !s.say.isEmpty else { return }
            self.prewarmed[key] = (calling, s, Date())
            // Keep it small: drop anything older than 30 minutes.
            self.prewarmed = self.prewarmed.filter { Date().timeIntervalSince($0.value.at) < 1800 }
            ActivityLog.add("Ready early: \(d.name)'s voicemail and follow-ups were written during this call")
        }
    }

    /// The next person's voicemail and follow-ups were written during the last call: a 1 second
    /// countdown is enough instead of 3.
    var nextIsReady: Bool {
        let id: String? = leads.isActive ? leads.nextRow?.id : callList.upNext()?.record.id
        return id.map { prewarmed[String($0.prefix(15))] != nil } ?? false
    }

    /// A real talk just ended and the rep hasn't said how it went yet: the bottom bar asks, with big buttons.
    var awaitingOutcome: Bool {
        guard status == .ready, lastCallAnswered, Salesforce.isConnected, let key = currentAttemptKey,
              Salesforce.objectFor(id: key) != nil, !outcomeSaved.contains(String(key.prefix(15))),
              !RemovedList.contains(key), !dialing,
              Date().timeIntervalSince(endedAt) < 120,
              statusRecordID.map({ $0.prefix(15) == key.prefix(15) }) == true else { return false }
        return true
    }

    /// The rep doesn't want to rate this call: move on now.
    func skipOutcome() {
        if let key = currentAttemptKey { outcomeSaved.insert(String(key.prefix(15))) }
        startNextSequence()
    }

    /// The voicemail written ahead of time for the person now opening, if there is one.
    func prewarmedVoicemail(for calling: String?) -> Suggestion? {
        let id = leads.isActive ? leads.details?.id : (callList.lastOpenedID ?? recordKey())
        guard let id, let ready = prewarmed[String(id.prefix(15))], Date().timeIntervalSince(ready.at) < 1800,
              // Same person by first name too, so one person's words can never land on another's card.
              Screener.firstName(ready.calling) == Screener.firstName(calling) else { return nil }
        return ready.voicemail
    }
}
