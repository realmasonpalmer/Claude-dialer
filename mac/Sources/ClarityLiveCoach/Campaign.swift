import Foundation

/// What the coach knows about this calling campaign. Phase 4 adds an editor;
/// for now there is one built-in campaign.
struct Campaign {
    var name: String
    var objective: String
    var playbook: String

    static let clarityDiscovery = Campaign(
        name: "Clarity: AI discovery calls",
        objective: "Book a 30 minute discovery meeting with the right person.",
        playbook: """
        ## Company
        Clarity Consulting helps businesses adopt Claude and fix workflows with AI.
        Salesforce partner and Anthropic Claude partner.
        Flagship: an AI notetaker plus Claude updating CRM fields after every call, so reps stop doing data entry.
        Also: Claude and AI health checks, Salesforce implementation, cleanup and automation.
        Never quote prices, results or client names on a cold call.

        ## Who we call
        Sales, RevOps and operations leaders at companies with a sales team, often on Salesforce.
        Common pains: reps lose hours to notes and CRM updates; messy CRM data; AI tools bought but not used; stalled AI projects.

        ## Opening script
        "Hi {first name}, it's {rep} with Clarity. This is a cold call. Can I take 30 seconds to tell you why I called?"

        ## Reason for the call
        "We help sales teams stop doing CRM data entry. Claude writes the notes and updates Salesforce after every call. How are your reps handling that today?"

        ## Discovery (2 or 3 questions, then move on)
        - How much time do reps spend on admin each week?
        - What happens to call notes today?
        - Who owns AI rollout on your team?
        - If you could fix one thing about your CRM data, what would it be?

        ## Closing
        Offer two specific times: "Do you have 30 minutes Tuesday at 10 or Thursday at 2?" Then confirm email and who else should join.

        ## Objections
        - Not interested: "Fair. Is that because CRM admin isn't a problem, or just not a priority right now?"
        - Send an email: "Happy to. What should it cover, the CRM updates or AI adoption?" Then try for a time.
        - Internal AI team: "That's great. Are they mostly building tools, or helping teams actually use AI?"
        - Another partner: "What's working with them, and what do you wish moved faster?"
        - No budget: "How many hours a week do reps lose to admin? That's usually where budget comes from."
        - Bad time: "When's better, later today or tomorrow morning?"
        - Not on Salesforce: "That's fine. We work with any CRM. How do you track deals today?"
        - Price: "It depends on scope, so I won't guess. That's what the 30 minutes is for."
        - Take me off your list: "Of course. Sorry to bother you." End the call.

        ## Gatekeeper
        "Could you help me out? Who handles sales operations or Salesforce there?" If blocked, get the best time and email.

        ## Voicemail (under 20 seconds)
        "Hi {first name}, it's {rep} with Clarity. We help sales teams stop doing CRM data entry with Claude. I'll send a short email."

        ## Success
        A meeting time is agreed. Then stop selling: confirm details and wrap up.

        ## Exit
        Two clear no's, a request not to be called, or no fit. Exit politely and leave the door open.
        """
    )
}
