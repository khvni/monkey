//
//  MonkeyReplayer.swift
//  leanring-buddy
//
//  Feature 3a — "teach once, run again" for Monkeybot.
//
//  HONEST scope (per the v0.3.0 features contract and cua's own docs): cua
//  element-index actions are per-snapshot and DO NOT survive a replay, so this
//  is NOT a pixel-perfect / passive action replay. Instead `MonkeyReplayer`
//  RE-RUNS a previously saved task: it reads `task.txt` from a saved run
//  directory and calls `MonkeyAgentLoop.run(task:voiceTranscript:)` again. The
//  loop re-observes the live UI and re-decides every action against FRESH
//  snapshots — so the element indices it uses are always valid. Frame this to
//  users as "re-run a saved workflow", never as deterministic replay.
//
//  Run directories are the ones written by `MonkeyTraceRecorder`, i.e.
//  `~/Documents/Monkeybot/runs/<timestamp>-<slug>/` (overridable via the
//  `MONKEYBOT_RUNS_DIR` environment variable so the two files agree on the base).
//
//  Additive + guarded: this file touches nothing on the verified v0.2.0 AX
//  element_index demo path. Reading saved runs is best-effort and never throws;
//  `rerun` simply funnels into the same `run` the live voice path uses.
//

import Foundation

/// Re-runs a previously saved Monkeybot workflow by replaying its TASK (not its
/// recorded low-level actions) through the live agent loop.
///
/// `@MainActor` because it drives `MonkeyAgentLoop`, which is `@MainActor`.
@MainActor
final class MonkeyReplayer {

    /// The live agent loop a re-run is funneled through. The replayer owns no
    /// driving logic of its own — it loads a saved task and hands it back to the
    /// exact same `run` the voice pipeline uses, so a re-run is indistinguishable
    /// from a fresh voice command except for where the task text came from.
    private let loop: MonkeyAgentLoop

    init(loop: MonkeyAgentLoop) {
        self.loop = loop
    }

    // MARK: - Saved-run discovery (static, side-effect-free reads)

    /// All saved run directories under the Monkeybot `runs/` base, NEWEST FIRST.
    ///
    /// Sort key is the directory's creation date (falling back to its name, which
    /// is timestamp-prefixed and therefore lexically time-ordered, then to the
    /// last path component). Best-effort: any filesystem error yields `[]` so a
    /// missing or unreadable runs directory can never crash a caller.
    static func listSavedRuns() -> [URL] {
        let fileManager = FileManager.default
        let runsBase = resolveRunsBaseDirectory()

        guard let entries = try? fileManager.contentsOfDirectory(
            at: runsBase,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let directories = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        return directories.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            // Tie-break on the timestamp-prefixed directory name (lexically time-ordered).
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
    }

    /// The most recent saved run directory, or nil when none exist. Convenience
    /// for the "re-run last saved workflow" entry point.
    static func mostRecentSavedRun() -> URL? {
        listSavedRuns().first
    }

    /// Loads the saved `task.txt` (and `transcript.txt`) from a run directory.
    ///
    /// Returns nil when `task.txt` is missing or empty — there is nothing to
    /// re-run without a task. `transcript.txt` is optional (an empty string is
    /// substituted when absent) because the loop only needs the task to re-decide;
    /// the transcript is passed through for the trace's provenance. Best-effort
    /// reads; never throws.
    static func loadTask(runDirectory: URL) -> (task: String, transcript: String)? {
        let taskURL = runDirectory.appendingPathComponent("task.txt", isDirectory: false)
        guard let rawTask = try? String(contentsOf: taskURL, encoding: .utf8) else {
            return nil
        }
        let task = rawTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }

        let transcriptURL = runDirectory.appendingPathComponent("transcript.txt", isDirectory: false)
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""

        return (task: task, transcript: transcript)
    }

    // MARK: - Re-run

    /// Re-runs the workflow saved in `runDirectory` by loading its `task.txt` and
    /// invoking `loop.run(task:voiceTranscript:)` again. This is the HONEST
    /// "run again": the loop re-decides every action against fresh snapshots, so
    /// element indices are always valid for the current UI.
    ///
    /// No-op (returns immediately) when the run directory has no readable task —
    /// there is nothing to re-run. The actual run is best-effort: `loop.run` owns
    /// all of its own error handling / trace recording and never throws.
    func rerun(runDirectory: URL) async {
        guard let saved = Self.loadTask(runDirectory: runDirectory) else { return }
        await loop.run(task: saved.task, voiceTranscript: saved.transcript)
    }

    // MARK: - Run base resolution (kept in lock-step with MonkeyTraceRecorder)

    /// Resolves the `runs/` base directory. MUST match `MonkeyTraceRecorder`'s
    /// resolution (default `~/Documents/Monkeybot/runs`, overridable via
    /// `MONKEYBOT_RUNS_DIR`) so the replayer sees exactly the directories the
    /// recorder writes. Read-only: never creates the directory.
    private static func resolveRunsBaseDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["MONKEYBOT_RUNS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fileManager = FileManager.default
        let documentsDirectory: URL
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            documentsDirectory = documents
        } else {
            documentsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        }
        return documentsDirectory
            .appendingPathComponent("Monkeybot", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }
}
