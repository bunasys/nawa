import AgentCore

/// What the chat asks after a run in which a model declined the prompt:
/// keep the exchange and continue, or take the prompt out of the context.
///
/// Every request resends the whole conversation, so a declined prompt left
/// in it can get later prompts declined too; removing it also sends the
/// next prompts back to the model that declined (see
/// `ChatSession.removeDeclinedRequest`). Both chat UIs ask the same
/// question and commit the same answer.
enum DeclinedRequest {
    /// Shown until the user answers: Enter keeps, `r` removes.
    static func question(_ notice: RefusalNotice) -> String {
        if let fallback = notice.answeredBy {
            return "Continue this conversation on \(fallback), or remove the declined request from the context?  enter: continue · r: remove"
        }
        return "Keep the declined request in the context? Later prompts may be declined too while it is there.  enter: keep · r: remove"
    }

    /// The answer typed in line mode: `r` (or `remove`) removes.
    static func wantsRemoval(_ answer: String) -> Bool {
        let word = answer.filter { !$0.isWhitespace }.lowercased()
        return word == "r" || word == "remove"
    }

    /// Carries out the answer and says what happened.
    static func answer(remove: Bool, notice: RefusalNotice, session: ChatSession) -> [Block] {
        guard remove else {
            let model = notice.answeredBy.map { " on \($0)" } ?? ""
            return [.note("kept; continuing\(model)")]
        }
        guard session.removeDeclinedRequest() else {
            return [.warning("the declined request is no longer in the context")]
        }
        var text = "removed the declined request and its replies from the context"
        let switchedModel = notice.answeredBy != nil
        if switchedModel, let original = notice.declinedBy {
            text += "; next prompts go to \(original)"
        }
        return [.note(text)]
    }

    /// What the transcript commits when a model declines.
    static func blocks(for notice: RefusalNotice) -> [Block] {
        var text = "\(notice.declinedBy ?? "the model") declined this request"
        if let category = notice.category { text += " (\(category))" }
        if let explanation = notice.explanation { text += ": \(explanation)" }
        var blocks: [Block] = [.warning(text)]
        if let fallback = notice.answeredBy {
            blocks.append(.note("\(fallback) answers instead"))
        }
        return blocks
    }

    /// The note for a run that ended with no model answering.
    static func unansweredNote(_ notice: RefusalNotice?) -> Block {
        if notice?.category == "reasoning_extraction" {
            return .note("no other model will help: reword the prompt so it doesn't ask for the model's reasoning")
        }
        return .note("no other model answered; NAWA_FALLBACK_MODEL names one to retry on")
    }
}
