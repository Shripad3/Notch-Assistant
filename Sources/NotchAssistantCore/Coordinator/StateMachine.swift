/// The six UI states from spec §4. The coordinator owns the current value;
/// presenters only render it.
public enum AssistantState: Sendable, Equatable {
    case idle
    case listening(partial: String)
    case thinking(transcript: String)
    case acting(tool: ToolLabel, target: String)
    case result(String)
    /// A Result that answers in words rather than reporting an action
    /// ("Hello"). Shown like a result; spoken unless speech is off.
    case reply(String)
    /// A Result with items to choose from (found files). Selecting one goes
    /// back through the coordinator.
    case list(String, [ResultItem])
    /// A change waiting for yes or no (a batch of files).
    case confirm(String, [ResultItem])
    case error(AssistantFailure)
}

public enum AssistantEvent: Sendable, Equatable {
    case activation
    case partial(String)
    case endpoint(String)
    /// Capture ended with no speech: back to Idle without invoking the model.
    case silence
    case cancel
    case toolCall(ToolLabel, target: String)
    case textOnly(String)
    case done(String, items: [ResultItem] = [])
    case needsConfirmation(String, [ResultItem])
    /// The user picked an item from a list; the outcome of acting on it.
    case selected(String)
    case failure(AssistantFailure)
    case dismiss
}

public enum StateMachine {
    /// Returns the next state, or nil when the event is not valid in `state`
    /// and must be ignored.
    ///
    /// Two edges go beyond the spec §4 diagram, both so that failures stay
    /// visible: Idle → Error (the model is unavailable at activation) and
    /// Listening → Error (a microphone or speech permission is missing).
    public static func transition(from state: AssistantState, on event: AssistantEvent) -> AssistantState? {
        switch (state, event) {
        case (.idle, .activation):
            .listening(partial: "")
        case (.listening, .partial(let text)):
            .listening(partial: text)
        case (.listening, .endpoint(let transcript)):
            .thinking(transcript: transcript)
        case (.listening, .silence):
            .idle
        case (.thinking, .toolCall(let tool, let target)), (.acting, .toolCall(let tool, let target)):
            .acting(tool: tool, target: target)
        case (.thinking, .textOnly(let text)):
            .reply(text)
        case (.acting, .done(let text, let items)):
            items.isEmpty ? .result(text) : .list(text, items)
        case (.acting, .needsConfirmation(let text, let items)):
            .confirm(text, items)
        case (.list, .selected(let text)), (.confirm, .selected(let text)):
            .result(text)
        case (.confirm, .activation):
            // Answering by voice: "Alfred, yes".
            .listening(partial: "")
        case (.idle, .failure(let failure)),
             (.listening, .failure(let failure)),
             (.thinking, .failure(let failure)),
             (.acting, .failure(let failure)),
             (.list, .failure(let failure)),
             (.confirm, .failure(let failure)):
            .error(failure)
        case (.result, .dismiss), (.reply, .dismiss), (.list, .dismiss), (.confirm, .dismiss), (.error, .dismiss):
            .idle
        case (.idle, .cancel):
            nil
        case (_, .cancel):
            .idle
        default:
            nil
        }
    }
}
