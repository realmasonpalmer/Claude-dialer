import Foundation

/// One calling campaign: what you sell, to whom, the script and the goal.
/// Every field is optional except the name. Claude reads the intent, not just the words.
struct Campaign: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New campaign"
    var objective = ""
    var pastedScript = ""
    var company = ""
    var offer = ""
    var idealCustomer = ""
    var persona = ""
    var opening = ""
    var discovery = ""
    var qualification = ""
    var objections = ""
    var transitions = ""
    var closing = ""
    var success = ""
    var exit = ""

    /// The sections, in the order the editor and the prompt show them.
    static let sections: [(key: WritableKeyPath<Campaign, String>, json: String, title: String, hint: String)] = [
        (\.company, "company", "Company", "Who you are, in a sentence or two."),
        (\.offer, "offer", "Product or service", "What you sell and the problem it solves."),
        (\.idealCustomer, "idealCustomer", "Ideal customer", "Which companies are a fit."),
        (\.persona, "persona", "Who you're calling", "Job titles and what they care about."),
        (\.opening, "opening", "Opening", "What to say in the first 10 seconds."),
        (\.discovery, "discovery", "Discovery questions", "Questions to ask, in rough order."),
        (\.qualification, "qualification", "Qualification", "What makes someone a good fit."),
        (\.objections, "objections", "Objections and approved answers", "Each objection and how to answer it."),
        (\.transitions, "transitions", "Transitions", "Phrases to move from one part to the next."),
        (\.closing, "closing", "Closing", "How to ask for the goal."),
        (\.success, "success", "Success", "How you know the goal is reached."),
        (\.exit, "exit", "When to stop", "When to end the call politely."),
    ]

    /// What Claude reads. Only filled-in sections are included.
    var promptText: String {
        var parts = ["# Campaign: \(name)"]
        parts.append("Objective: \(objective.isEmpty ? "Not set. Infer it from the script." : objective)")
        for section in Self.sections where !self[keyPath: section.key].trimmed.isEmpty {
            parts.append("## \(section.title)\n\(self[keyPath: section.key].trimmed)")
        }
        if !pastedScript.trimmed.isEmpty {
            parts.append("## Original script (follow its intent and tone, not word for word)\n\(pastedScript.trimmed)")
        }
        return parts.joined(separator: "\n\n")
    }

    static let clarityDiscovery = Campaign(
        name: "Clarity: AI discovery calls",
        objective: "Book a 30 minute discovery meeting with the right person.",
        company: "Clarity Consulting helps businesses adopt Claude and fix workflows with AI. Salesforce partner and Anthropic Claude partner. Never quote prices, results or client names on a cold call.",
        offer: "An AI notetaker plus Claude updating CRM fields after every call, so reps stop doing data entry. Also Claude and AI health checks, and Salesforce implementation, cleanup and automation.",
        idealCustomer: "Companies with a sales team, often on Salesforce.",
        persona: "Sales, RevOps and operations leaders. Pains: reps lose hours to notes and CRM updates, messy CRM data, AI tools bought but not used, stalled AI projects.",
        opening: "\"Hi {first name}, it's {rep} with Clarity. This is a cold call. Can I take 30 seconds to tell you why I called?\" Then: \"We help sales teams stop doing CRM data entry. Claude writes the notes and updates Salesforce after every call. How are your reps handling that today?\"",
        discovery: "- How much time do reps spend on admin each week?\n- What happens to call notes today?\n- Who owns AI rollout on your team?\n- If you could fix one thing about your CRM data, what would it be?",
        qualification: "Has a sales team. Feels the admin or adoption pain. Is the decision maker or can bring them.",
        objections: "- Not interested: \"Fair. Is that because CRM admin isn't a problem, or just not a priority right now?\"\n- Send an email: \"Happy to. What should it cover, the CRM updates or AI adoption?\" Then try for a time.\n- Internal AI team: \"That's great. Are they mostly building tools, or helping teams actually use AI?\"\n- Another partner: \"What's working with them, and what do you wish moved faster?\"\n- No budget: \"How many hours a week do reps lose to admin? That's usually where budget comes from.\"\n- Bad time: \"When's better, later today or tomorrow morning?\"\n- Not on Salesforce: \"That's fine. We work with any CRM. How do you track deals today?\"\n- Price: \"It depends on scope, so I won't guess. That's what the 30 minutes is for.\"\n- Take me off your list: \"Of course. Sorry to bother you.\" End the call.\n- Gatekeeper: \"Could you help me out? Who handles sales operations or Salesforce there?\"\n- Voicemail (under 20 seconds): \"Hi {first name}, it's {rep} with Clarity. We help sales teams stop doing CRM data entry with Claude. I'll send a short email.\"",
        transitions: "\"Makes sense.\" \"That's what we hear a lot.\" \"Can I ask one more question?\"",
        closing: "Offer two specific times: \"Do you have 30 minutes Tuesday at 10 or Thursday at 2?\" Then confirm email and who else should join.",
        success: "A meeting time is agreed. Then stop selling: confirm details and wrap up.",
        exit: "Two clear no's, a request not to be called, or no fit. Exit politely and leave the door open."
    )
}

/// Saves campaigns as small files on this Mac:
/// ~/Library/Application Support/Clarity Live Coach/Campaigns
@MainActor
final class CampaignStore: ObservableObject {
    @Published private(set) var campaigns: [Campaign] = []
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "selectedCampaign") }
    }
    /// The campaign open in the editor window.
    @Published var editing: Campaign?

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Clarity Live Coach/Campaigns", isDirectory: true)
    }()

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        campaigns = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Campaign.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
        if campaigns.isEmpty {
            save(.clarityDiscovery)
        }
        let saved = UserDefaults.standard.string(forKey: "selectedCampaign").flatMap(UUID.init)
        selectedID = campaigns.contains { $0.id == saved } ? saved : campaigns.first?.id
    }

    var selected: Campaign { campaigns.first { $0.id == selectedID } ?? campaigns.first ?? .clarityDiscovery }

    func save(_ campaign: Campaign) {
        if let data = try? JSONEncoder().encode(campaign) {
            try? data.write(to: file(for: campaign), options: .atomic)
        }
        if let index = campaigns.firstIndex(where: { $0.id == campaign.id }) {
            campaigns[index] = campaign
        } else {
            campaigns.append(campaign)
            campaigns.sort { $0.name < $1.name }
        }
    }

    func delete(_ campaign: Campaign) {
        try? FileManager.default.removeItem(at: file(for: campaign))
        campaigns.removeAll { $0.id == campaign.id }
        if campaigns.isEmpty { save(.clarityDiscovery) }
        if selectedID == campaign.id { selectedID = campaigns.first?.id }
    }

    private func file(for campaign: Campaign) -> URL {
        folder.appendingPathComponent("\(campaign.id.uuidString).json")
    }
}
