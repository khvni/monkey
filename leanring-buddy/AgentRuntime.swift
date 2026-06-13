import Foundation

// MARK: - Step Record

/// Compact record of one executed step, fed back to the runtime as history.
///
/// The agent loop accumulates these after each observe-act-verify turn and
/// hands the recent ones to the runtime so the model can reason about what it
/// has already tried. Codable so it can also be appended to `steps.jsonl` by
/// the trace recorder.
struct MonkeyStepRecord: Codable {
    /// 1-based index of this step within the run.
    let stepNumber: Int
    /// The validated action that was chosen and executed this step.
    let action: MonkeyAction
    /// Short success/error summary of executing `action` via the cua driver.
    let result: String
    /// Post-action observation delta summary (e.g. "focused field changed",
    /// "element appeared"). `nil` when no verification was performed.
    let verification: String?
}

// MARK: - Agent Context

/// Everything the runtime needs to choose the next single action.
///
/// Built fresh by the agent loop on every turn. `observationMarkdown` and the
/// element indices it references are snapshot-scoped: they are only valid until
/// the next `get_window_state`, so the runtime must target elements using the
/// indices present in the current observation.
struct AgentContext {
    /// The user task to accomplish (typically the finalized voice transcript).
    let task: String
    /// Raw voice transcript that produced the task, for additional intent context.
    let voiceTranscript: String
    /// Human-readable name of the application/window being driven.
    let targetApplicationName: String
    /// Pruned `get_window_state` `tree_markdown` for the current snapshot.
    let observationMarkdown: String
    /// File paths of the most recent screenshots (last 1...3), may be empty.
    let recentScreenshotFilePaths: [String]
    /// Compact history of previously executed steps.
    let priorSteps: [MonkeyStepRecord]
    /// 1-based index of the step about to be decided.
    let stepNumber: Int
    /// Hard cap on total steps for this run.
    let maxSteps: Int
}

// MARK: - Agent Runtime

/// Pluggable agent brain. Returns exactly ONE validated `MonkeyAction` per call.
///
/// This is the future-compatible seam for the agent loop. Only
/// `ClaudeAgentRuntime` (defined separately) is implemented today. Additional
/// backends such as ACP or Codex can conform later — intentionally left
/// unimplemented here.
protocol AgentRuntime {
    /// Stable identifier for the backend (e.g. "claude"), used in traces/logs.
    var runtimeName: String { get }

    /// Decide the single next action given the current context.
    ///
    /// Implementations must return a `MonkeyAction` that has already passed
    /// `validate()`, or throw if a well-formed action could not be produced.
    func decideNextAction(context: AgentContext) async throws -> MonkeyAction
}
