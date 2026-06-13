//
//  ClaudeAgentRuntime.swift
//  Monkeybot agent brain backed by the EXISTING Claude API path (Worker /chat SSE).
//
//  Conforms to AgentRuntime (AgentRuntime.swift) and emits exactly ONE validated
//  MonkeyAction (MonkeyAction.swift) per call. It receives an already-built ClaudeAPI
//  instance — it NEVER constructs one, because the Cloudflare proxy URL and selected
//  model are injected upstream by CompanionManager.claudeAPI. Cloudflare auth is
//  untouched here.
//

import Foundation

/// Pluggable agent brain that asks Claude to choose the next single cua action.
///
/// The runtime builds a strict-JSON system prompt documenting the MonkeyAction schema,
/// supplies the pruned observation markdown plus the most recent screenshot(s) plus a
/// compact prior-step history, then parses and validates the model's reply. On malformed
/// JSON it re-prompts exactly once with the bad output and a correction instruction.
final class ClaudeAgentRuntime: AgentRuntime {
    let runtimeName = "claude"

    /// Already-built Claude client (proxy URL + model injected by CompanionManager).
    private let claudeApi: ClaudeAPI

    /// Cap on recent screenshots forwarded to the model. The loop keeps 1...3; we defend
    /// against accidentally shipping a large image history that would balloon the payload.
    private let maximumScreenshotsPerTurn = 3

    init(claudeApi: ClaudeAPI) {
        self.claudeApi = claudeApi
    }

    // MARK: - AgentRuntime

    func decideNextAction(context: AgentContext) async throws -> MonkeyAction {
        let systemPrompt = Self.buildSystemPrompt(context: context)
        let userPrompt = Self.buildUserPrompt(context: context)
        let images = loadRecentScreenshots(context: context)

        // First attempt. We use the STREAMING method (max_tokens = 1024) and ignore the
        // chunks, reading only the fully accumulated return text. The non-streaming
        // analyzeImage hard-codes max_tokens = 256, which can truncate a verbose
        // reason/summary into invalid JSON; 1024 gives the small action object room.
        let firstResponseText: String
        do {
            let (fullText, _) = try await claudeApi.analyzeImageStreaming(
                images: images,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )
            firstResponseText = fullText
        } catch {
            // Network/HTTP failures are surfaced to the loop, which logs and stops.
            throw error
        }

        // Try to parse + validate the first reply.
        do {
            let action = try MonkeyAction.parse(fromModelText: firstResponseText)
            try action.validate()
            return action
        } catch let firstError {
            // Malformed or schema-invalid JSON: re-prompt exactly once. We feed the prior
            // (bad) assistant output back as a single conversation-history turn and ask for
            // a corrected single JSON object. Images are dropped on the retry — the model
            // already has the observation context, and resending images wastes payload.
            let correctionPrompt = Self.buildCorrectionPrompt(
                badOutput: firstResponseText,
                parseError: firstError
            )
            let priorTurn: [(userPlaceholder: String, assistantResponse: String)] = [
                (userPlaceholder: userPrompt, assistantResponse: firstResponseText)
            ]

            let (retryText, _) = try await claudeApi.analyzeImageStreaming(
                images: [],
                systemPrompt: systemPrompt,
                conversationHistory: priorTurn,
                userPrompt: correctionPrompt,
                onTextChunk: { _ in }
            )

            // A second failure propagates to the loop (the loop also guards / stops
            // gracefully). We surface the ORIGINAL parse error context via the thrown error.
            let action = try MonkeyAction.parse(fromModelText: retryText)
            try action.validate()
            return action
        }
    }

    // MARK: - Screenshots

    /// Loads the most recent screenshot PNG(s) from disk into the (data, label) form the
    /// Claude API expects. Missing/unreadable files are skipped (no throw) so a single
    /// stale path never aborts the turn. Newest-first, capped at `maximumScreenshotsPerTurn`.
    private func loadRecentScreenshots(context: AgentContext) -> [(data: Data, label: String)] {
        let paths = Array(context.recentScreenshotFilePaths.suffix(maximumScreenshotsPerTurn))
        let totalKept = paths.count
        return paths.enumerated().compactMap { offset, path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            // Label the freshest capture clearly so the model knows which frame is current.
            let isMostRecent = (offset == totalKept - 1)
            let label = isMostRecent
                ? "Current window screenshot (most recent — reflects the live UI state)"
                : "Earlier window screenshot (for context only; may be stale)"
            return (data: data, label: label)
        }
    }

    // MARK: - Prompt construction

    /// System prompt: role, the cua action schema (EXACT JSON keys from MonkeyAction),
    /// the one-object-no-prose hard rule, and the snapshot-scoped element_index rule.
    private static func buildSystemPrompt(context: AgentContext) -> String {
        return """
        You are Monkeybot, an autonomous macOS UI agent. You drive a real application by \
        emitting ONE structured action at a time. A separate executor runs each action \
        through the cua-driver accessibility/automation tool, then sends you a fresh \
        observation. You repeat: observe -> decide one action -> observe again.

        # YOUR TASK
        \(context.task)

        Target application: \(context.targetApplicationName)
        This is step \(context.stepNumber) of at most \(context.maxSteps).

        # OUTPUT CONTRACT — READ CAREFULLY
        Reply with EXACTLY ONE JSON object and NOTHING else.
        - No prose, no explanation, no greeting, no trailing commentary.
        - No markdown code fences (do NOT wrap it in ```json ... ```).
        - The entire reply must be a single parseable JSON object: it starts with `{` and \
        ends with `}`.
        - Put any reasoning ONLY inside the optional "reason" string field (keep it short, \
        one sentence). Never write reasoning outside the JSON.

        # ACTION SCHEMA
        The object has a required "action" field whose value is one of:
        observe, click, type_text, set_value, scroll, press_key, hotkey, wait, done, ask_user

        Every action MAY include:
          "reason": string   // short rationale, logged to the trace (optional but encouraged)

        Per-action required and optional fields (use these EXACT JSON keys):

        - observe        : take a fresh look; no other fields. Use when you need an updated \
        view before acting.
        - click          : click a UI element.
                           Required: EITHER "element_index" (int) OR both "x" (number) and \
        "y" (number).
                           Prefer "element_index" from the CURRENT observation. Use raw \
        "x"/"y" screen coordinates ONLY when no accessibility element matches.
        - type_text      : type characters into the focused field.
                           Required: "text" (string).
                           Optional: "element_index" (int) to focus a field first.
        - set_value      : directly set a field's value (faster/cleaner than typing).
                           Required: "element_index" (int) AND "value" (string).
        - scroll         : scroll within the window or an element.
                           Required: "direction" (one of "up","down","left","right").
                           Optional: "by" (one of "line","page"), "amount" (int repetitions), \
        "element_index" (int).
        - press_key      : press a single key.
                           Required: "key" (string, e.g. "Return", "Escape", "Tab").
        - hotkey         : press a key combination.
                           Required: "keys" (non-empty array of strings, e.g. ["cmd","c"]).
        - wait           : pause before the next observation.
                           Required: "seconds" (number; if you omit it, 1 second is assumed).
        - done           : the task is complete.
                           Required: "summary" (string describing what was accomplished).
        - ask_user       : you are blocked and need human input.
                           Required: "question" (string to surface to the user).

        # ELEMENT INDEX RULE (CRITICAL)
        "element_index" values are SNAPSHOT-SCOPED: they are valid ONLY for the observation \
        shown in THIS turn. After ANY action the UI changes and indices are renumbered, so \
        NEVER reuse an "element_index" from an earlier step. Always pick indices from the \
        observation in the current user message. If you are unsure the indices are still \
        valid, emit {"action":"observe"} to refresh before acting.

        # STRATEGY
        - Emit the single most useful next action toward the task.
        - Prefer accessibility targeting ("element_index", "set_value") over raw coordinates.
        - When the goal is achieved, emit a "done" action with a clear "summary".
        - If a required control is missing, ambiguous, or you need a human decision, emit \
        "ask_user" rather than guessing destructively.
        - Stay within \(context.maxSteps) steps; be decisive.

        # EXAMPLES (shape only — match the current observation, do not copy indices)
        {"action":"click","element_index":12,"reason":"open the search field"}
        {"action":"type_text","text":"hello world","reason":"enter the query"}
        {"action":"set_value","element_index":4,"value":"jane@example.com"}
        {"action":"hotkey","keys":["cmd","return"],"reason":"submit the form"}
        {"action":"scroll","direction":"down","by":"page","amount":1}
        {"action":"done","summary":"Submitted the contact form successfully."}
        """
    }

    /// User prompt: voice transcript (verbatim intent), the pruned observation markdown,
    /// and a compact prior-step history. Screenshots travel as separate image blocks.
    private static func buildUserPrompt(context: AgentContext) -> String {
        var sections: [String] = []

        sections.append("# STEP \(context.stepNumber) of \(context.maxSteps)")

        if !context.voiceTranscript.isEmpty {
            sections.append("""
            # USER REQUEST (verbatim voice transcript)
            \(context.voiceTranscript)
            """)
        }

        sections.append("""
        # GOAL
        \(context.task)
        """)

        let historyBlock = compactHistory(context.priorSteps)
        if historyBlock.isEmpty {
            sections.append("""
            # PRIOR STEPS
            (none — this is the first action)
            """)
        } else {
            sections.append("""
            # PRIOR STEPS (most recent last)
            \(historyBlock)
            """)
        }

        let observation = context.observationMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let observationBody = observation.isEmpty
            ? "(no accessibility tree available — rely on the screenshot)"
            : observation
        sections.append("""
        # CURRENT OBSERVATION (window_state — element_index values are valid ONLY for THIS snapshot)
        \(observationBody)
        """)

        if context.recentScreenshotFilePaths.isEmpty {
            sections.append("# SCREENSHOTS\n(none attached this turn)")
        }

        sections.append("""
        Respond now with EXACTLY ONE JSON action object and nothing else.
        """)

        return sections.joined(separator: "\n\n")
    }

    /// Renders prior steps as compact one-liners so history stays cheap in tokens.
    /// Keeps only the last several steps; older steps are summarized as a count.
    private static func compactHistory(_ steps: [MonkeyStepRecord]) -> String {
        guard !steps.isEmpty else { return "" }

        let maximumDetailedSteps = 8
        let detailed: [MonkeyStepRecord]
        var lines: [String] = []

        if steps.count > maximumDetailedSteps {
            let droppedCount = steps.count - maximumDetailedSteps
            lines.append("(\(droppedCount) earlier step(s) omitted)")
            detailed = Array(steps.suffix(maximumDetailedSteps))
        } else {
            detailed = steps
        }

        for record in detailed {
            var parts: [String] = []
            parts.append("step \(record.stepNumber): \(actionDescriptor(record.action))")
            parts.append("-> \(record.result)")
            if let verification = record.verification, !verification.isEmpty {
                parts.append("(\(verification))")
            }
            lines.append(parts.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }

    /// One-line human-readable descriptor of an executed action for the history block.
    private static func actionDescriptor(_ action: MonkeyAction) -> String {
        switch action.action {
        case .observe:
            return "observe"
        case .click:
            if let index = action.elementIndex {
                return "click element_index \(index)"
            } else if let x = action.x, let y = action.y {
                return "click (\(Int(x)),\(Int(y)))"
            }
            return "click"
        case .type_text:
            let snippet = truncate(action.text ?? "", limit: 40)
            return "type_text \"\(snippet)\""
        case .set_value:
            let snippet = truncate(action.value ?? "", limit: 40)
            if let index = action.elementIndex {
                return "set_value element_index \(index) = \"\(snippet)\""
            }
            return "set_value \"\(snippet)\""
        case .scroll:
            return "scroll \(action.direction ?? "?")"
        case .press_key:
            return "press_key \(action.key ?? "?")"
        case .hotkey:
            return "hotkey \((action.keys ?? []).joined(separator: "+"))"
        case .wait:
            let seconds = action.seconds ?? 1
            return "wait \(seconds)s"
        case .done:
            return "done: \(truncate(action.summary ?? "", limit: 60))"
        case .ask_user:
            return "ask_user: \(truncate(action.question ?? "", limit: 60))"
        }
    }

    /// Correction prompt for the single re-prompt after a malformed/invalid first reply.
    private static func buildCorrectionPrompt(badOutput: String, parseError: Error) -> String {
        let trimmedBad = truncate(badOutput.trimmingCharacters(in: .whitespacesAndNewlines), limit: 600)
        return """
        Your previous reply was NOT a single valid MonkeyAction JSON object and could not be \
        used.

        Parser error: \(String(describing: parseError))

        Your previous reply was:
        \(trimmedBad)

        Reply AGAIN with EXACTLY ONE JSON object that conforms to the action schema in the \
        system prompt. Output ONLY the JSON object — it must start with `{` and end with \
        `}`, with no prose and no markdown code fences. Include all fields required for the \
        chosen "action".
        """
    }

    /// Truncates a string for compact logging/prompting, appending an ellipsis when cut.
    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[text.startIndex..<endIndex]) + "…"
    }
}
