//
//  MonkeyAgentLoop.swift
//  Observe-act-verify orchestrator for the Monkeybot agentic computer-use loop.
//
//  Pure orchestration logic. UI-agnostic: publishes progress through `state`
//  (an ObservableObject the floating HUD binds to). Codes strictly to the
//  LOCKED CONTRACT interfaces of CuaDriverClient, AgentRuntime, MonkeyAction,
//  and MonkeyTraceRecorder (see /tmp/monkeybot-contract.md, FILE 6).
//

import Foundation
import Combine
import AppKit

/// Observable snapshot of the running loop, consumed by the Monkeybot HUD.
struct MonkeyLoopState {
    var isRunning: Bool
    var task: String
    var targetApplication: String
    var stepNumber: Int
    var maxSteps: Int
    var lastActionSummary: String
    /// Short human-readable status, e.g. "observing", "clicking [12]", "done".
    var statusLine: String
    var traceDirectory: String?
    /// When the loop ends via an `ask_user` action, the question is surfaced here.
    var pendingUserQuestion: String?
    /// Set when the loop terminates because of an unrecoverable failure.
    var failureMessage: String?

    static func idle(maxSteps: Int) -> MonkeyLoopState {
        MonkeyLoopState(
            isRunning: false,
            task: "",
            targetApplication: "",
            stepNumber: 0,
            maxSteps: maxSteps,
            lastActionSummary: "",
            statusLine: "idle",
            traceDirectory: nil,
            pendingUserQuestion: nil,
            failureMessage: nil
        )
    }
}

/// Drives the agentic computer-use loop: observe the target Chrome window,
/// ask the runtime for ONE action, validate it, execute it via the cua-driver,
/// re-observe, record the step, and repeat until completion / stop / limit.
@MainActor
final class MonkeyAgentLoop: ObservableObject {
    @Published private(set) var state: MonkeyLoopState

    private let cuaDriverClient: CuaDriverClient
    private let agentRuntime: AgentRuntime
    private let maximumStepCount: Int

    /// Cooperative-cancellation flag toggled by `stop()`. Checked at every
    /// loop boundary so the user's Stop button takes effect promptly.
    private var stopRequested: Bool = false

    /// Number of screenshots from the most recent observations to keep in the
    /// model's context. Disk retains every artifact; the model only needs the
    /// freshest few to stay grounded without blowing up the prompt.
    private let recentScreenshotWindowSize: Int = 3

    init(cua: CuaDriverClient, runtime: AgentRuntime, maxSteps: Int = 20) {
        self.cuaDriverClient = cua
        self.agentRuntime = runtime
        self.maximumStepCount = maxSteps
        self.state = MonkeyLoopState.idle(maxSteps: maxSteps)
    }

    /// User pressed Stop. Cooperatively cancels at the next loop boundary.
    func stop() {
        stopRequested = true
        state.statusLine = "stopping"
    }

    /// Main entry point. Targets the frontmost Google Chrome window, then runs
    /// the observe → decide → validate → execute → re-observe → record loop
    /// until the agent reports `done`, the user stops, the step limit is hit,
    /// or a failure occurs.
    func run(task: String, voiceTranscript: String) async {
        stopRequested = false

        let traceSlug = Self.makeTraceSlug(fromTask: task)
        let traceRecorder = MonkeyTraceRecorder(
            task: task,
            transcript: voiceTranscript,
            slug: traceSlug
        )
        let traceDirectoryPath = traceRecorder.runDirectoryURL.path

        state = MonkeyLoopState(
            isRunning: true,
            task: task,
            targetApplication: "",
            stepNumber: 0,
            maxSteps: maximumStepCount,
            lastActionSummary: "",
            statusLine: "locating target window",
            traceDirectory: traceDirectoryPath,
            pendingUserQuestion: nil,
            failureMessage: nil
        )

        // 1. Find the frontmost Google Chrome window and bring it to front.
        let targetWindow: CuaWindow
        do {
            guard let chromeWindow = try await locateFrontmostChromeWindow() else {
                surfaceUserQuestion(
                    "I could not find an open Google Chrome window. Please open Chrome and try again.",
                    recorder: traceRecorder
                )
                return
            }
            targetWindow = chromeWindow
        } catch {
            finishWithFailure(
                "Failed to list windows: \(Self.describe(error))",
                recorder: traceRecorder
            )
            return
        }

        state.targetApplication = "\(targetWindow.appName) — \(targetWindow.title)"
        state.statusLine = "bringing window to front"

        // Raising the window is BEST-EFFORT, not fatal: cua's get_window_state /
        // AX actions work on backgrounded windows via element_index, so a failed
        // focus must not abort the run. We do two things:
        //  1. NSRunningApplication.activate — the real macOS raise (cua's
        //     bring_to_front is a Windows-only no-op on macOS, verified via the
        //     live binary: exit=1, "bring_to_front is Windows-only"). This makes
        //     the Clay window visible to the audience during the demo.
        //  2. cua bringToFront — kept as a cross-platform best-effort; its macOS
        //     no-op is swallowed inside the client.
        activateApplication(pid: targetWindow.pid)
        try? await cuaDriverClient.bringToFront(
            pid: targetWindow.pid,
            windowId: targetWindow.windowId
        )

        // Rolling history fed back to the runtime, plus the screenshots kept in
        // the model's context (most recent first .. trimmed to the window size).
        var priorStepRecords: [MonkeyStepRecord] = []
        var recentScreenshotPaths: [String] = []

        // 2. Initial observation before the first action.
        var currentObservation: CuaObservation
        do {
            state.statusLine = "observing"
            currentObservation = try await observeTargetWindow(targetWindow, stepNumber: 0)
        } catch {
            finishWithFailure(
                "Initial observation failed: \(Self.describe(error))",
                recorder: traceRecorder
            )
            return
        }

        // Record the initial observation as step 0's context and seed screenshots.
        traceRecorder.recordObservation(
            stepNumber: 0,
            markdown: currentObservation.treeMarkdown
        )
        if let savedScreenshotRelativePath = traceRecorder.recordScreenshotSourcePath(
            currentObservation.screenshotFilePath,
            stepNumber: 0
        ) {
            let absolutePath = traceRecorder.runDirectoryURL
                .appendingPathComponent(savedScreenshotRelativePath)
                .path
            recentScreenshotPaths = trimToRecent([absolutePath])
        }
        // The recorder COPIES into the run dir; remove the transient temp PNG.
        Self.removeTemporaryFile(currentObservation.screenshotFilePath)

        // 3. The observe-act-verify loop. One model action per turn; re-snapshot
        // after every action because element indices are snapshot-scoped.
        var stepNumber = 1
        while stepNumber <= maximumStepCount {
            if stopRequested {
                finishStopped(recorder: traceRecorder)
                return
            }

            state.stepNumber = stepNumber
            state.statusLine = "thinking"

            let agentContext = AgentContext(
                task: task,
                voiceTranscript: voiceTranscript,
                targetApplicationName: targetWindow.appName,
                observationMarkdown: Self.capObservation(currentObservation.treeMarkdown),
                recentScreenshotFilePaths: recentScreenshotPaths,
                priorSteps: priorStepRecords,
                stepNumber: stepNumber,
                maxSteps: maximumStepCount
            )

            // --- DECIDE ---------------------------------------------------
            let decidedAction: MonkeyAction
            do {
                decidedAction = try await agentRuntime.decideNextAction(context: agentContext)
            } catch {
                let failureSummary = "Runtime failed to decide an action: \(Self.describe(error))"
                recordFailureStep(
                    stepNumber: stepNumber,
                    summary: failureSummary,
                    recorder: traceRecorder,
                    priorStepRecords: &priorStepRecords
                )
                finishWithFailure(failureSummary, recorder: traceRecorder)
                return
            }

            if stopRequested {
                finishStopped(recorder: traceRecorder)
                return
            }

            // --- VALIDATE -------------------------------------------------
            do {
                try decidedAction.validate()
            } catch {
                // A malformed action is logged but not fatal: skip it and let the
                // runtime try again on the next turn with the same observation.
                let validationSummary = "Invalid action (\(decidedAction.action.rawValue)): \(Self.describe(error))"
                state.lastActionSummary = validationSummary
                let record = MonkeyStepRecord(
                    stepNumber: stepNumber,
                    action: decidedAction,
                    result: validationSummary,
                    verification: nil
                )
                traceRecorder.recordStep(record, observationFile: nil, screenshotFile: nil)
                priorStepRecords.append(record)
                stepNumber += 1
                continue
            }

            // --- TERMINAL & NON-DRIVER ACTIONS ----------------------------
            switch decidedAction.action {
            case .done:
                let summaryText = decidedAction.summary ?? "Task reported complete."
                let record = MonkeyStepRecord(
                    stepNumber: stepNumber,
                    action: decidedAction,
                    result: "done: \(summaryText)",
                    verification: nil
                )
                traceRecorder.recordStep(record, observationFile: nil, screenshotFile: nil)
                priorStepRecords.append(record)
                finishDone(summary: summaryText, recorder: traceRecorder)
                return

            case .ask_user:
                let question = decidedAction.question ?? "I need more information to continue."
                let record = MonkeyStepRecord(
                    stepNumber: stepNumber,
                    action: decidedAction,
                    result: "ask_user: \(question)",
                    verification: nil
                )
                traceRecorder.recordStep(record, observationFile: nil, screenshotFile: nil)
                priorStepRecords.append(record)
                surfaceUserQuestion(question, recorder: traceRecorder)
                return

            case .wait:
                let waitSeconds = decidedAction.seconds ?? 1
                state.lastActionSummary = decidedAction.reason ?? "waiting \(Self.format(seconds: waitSeconds))s"
                state.statusLine = "waiting \(Self.format(seconds: waitSeconds))s"
                await sleep(seconds: waitSeconds)

            case .observe:
                // Explicit re-observation request. The unconditional re-snapshot
                // below satisfies it; nothing extra to execute here.
                state.lastActionSummary = decidedAction.reason ?? "observing"
                state.statusLine = "observing"

            case .click, .type_text, .set_value, .scroll, .press_key, .hotkey:
                // --- EXECUTE via cua-driver -------------------------------
                state.statusLine = Self.statusLine(for: decidedAction)
                state.lastActionSummary = Self.actionSummary(for: decidedAction)
                do {
                    try await execute(action: decidedAction, on: targetWindow)
                } catch {
                    let executionSummary = "Execution failed (\(decidedAction.action.rawValue)): \(Self.describe(error))"
                    recordFailureStep(
                        stepNumber: stepNumber,
                        action: decidedAction,
                        summary: executionSummary,
                        recorder: traceRecorder,
                        priorStepRecords: &priorStepRecords
                    )
                    finishWithFailure(executionSummary, recorder: traceRecorder)
                    return
                }
            }

            if stopRequested {
                finishStopped(recorder: traceRecorder)
                return
            }

            // --- RE-OBSERVE (every turn) ----------------------------------
            let observationBeforeAction = currentObservation
            state.statusLine = "verifying"
            do {
                currentObservation = try await observeTargetWindow(targetWindow, stepNumber: stepNumber)
            } catch {
                let observeSummary = "Re-observation failed: \(Self.describe(error))"
                recordFailureStep(
                    stepNumber: stepNumber,
                    action: decidedAction,
                    summary: observeSummary,
                    recorder: traceRecorder,
                    priorStepRecords: &priorStepRecords
                )
                finishWithFailure(observeSummary, recorder: traceRecorder)
                return
            }

            // Persist the post-action observation + screenshot, refresh context.
            let observationFile = traceRecorder.recordObservation(
                stepNumber: stepNumber,
                markdown: currentObservation.treeMarkdown
            )
            let savedScreenshotFile = traceRecorder.recordScreenshotSourcePath(
                currentObservation.screenshotFilePath,
                stepNumber: stepNumber
            )
            if let savedScreenshotFile {
                let absolutePath = traceRecorder.runDirectoryURL
                    .appendingPathComponent(savedScreenshotFile)
                    .path
                recentScreenshotPaths = trimToRecent(recentScreenshotPaths + [absolutePath])
            }
            // The recorder COPIES into the run dir; remove the transient temp PNG.
            Self.removeTemporaryFile(currentObservation.screenshotFilePath)

            // --- VERIFY: short observation delta for the step record ------
            let verificationSummary = Self.verificationDelta(
                before: observationBeforeAction,
                after: currentObservation
            )

            let stepRecord = MonkeyStepRecord(
                stepNumber: stepNumber,
                action: decidedAction,
                result: Self.actionSummary(for: decidedAction),
                verification: verificationSummary
            )
            traceRecorder.recordStep(
                stepRecord,
                observationFile: observationFile,
                screenshotFile: savedScreenshotFile
            )
            priorStepRecords.append(stepRecord)

            stepNumber += 1
        }

        // 4. Hit the step ceiling without a `done`.
        finishStepLimit(recorder: traceRecorder)
    }

    // MARK: - Target window selection

    /// Returns the real Google Chrome browser window to drive, if any.
    ///
    /// A live probe of a typical machine showed Chrome reports ~12 layer-0
    /// windows, most of which are tiny off-screen helper surfaces (empty title,
    /// is_on_screen=false, a few px each). Picking "the first Chrome window"
    /// would grab one of those and the demo would observe an empty AX tree.
    ///
    /// Heuristic, in priority order:
    ///  1. Keep only Google Chrome windows.
    ///  2. Strongly prefer the window whose title mentions the demo target
    ///     ("Clay") so a multi-window setup lands on the right tab.
    ///  3. Otherwise prefer on-screen windows that have a non-empty title
    ///     (a real browser frame, not a helper), and among those pick the
    ///     largest by area.
    ///  4. Fall back to the largest Chrome window overall.
    private func locateFrontmostChromeWindow() async throws -> CuaWindow? {
        let windows = try await cuaDriverClient.listWindows()
        let chromeWindows = windows.filter {
            $0.appName.localizedCaseInsensitiveContains("Chrome")
        }
        if chromeWindows.isEmpty { return nil }

        func area(_ window: CuaWindow) -> Double { window.bounds.width * window.bounds.height }

        // 2. Title mentions the demo target — pick the largest such window.
        let clayWindows = chromeWindows
            .filter { $0.title.localizedCaseInsensitiveContains("clay") }
            .sorted { area($0) > area($1) }
        if let clayWindow = clayWindows.first { return clayWindow }

        // 3. On-screen real browser frames (non-empty title), largest first.
        let onScreenTitled = chromeWindows
            .filter { $0.isOnScreen && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { area($0) > area($1) }
        if let bestVisible = onScreenTitled.first { return bestVisible }

        // 4. Last resort: the largest Chrome window of any kind.
        return chromeWindows.sorted { area($0) > area($1) }.first
    }

    /// Performs the real macOS window raise the cua no-op can't. Best-effort:
    /// activation can fail silently (e.g. another app holds focus) and that is
    /// acceptable because AX actions work on backgrounded windows anyway.
    private func activateApplication(pid: Int) {
        guard let runningApplication = NSRunningApplication(processIdentifier: pid_t(pid)) else { return }
        runningApplication.activate(options: [.activateAllWindows])
    }

    /// Snapshots the target window, requesting a screenshot written to a unique
    /// temp PNG so the driver runs its screenshot capture path (instead of the
    /// AX-only mode it uses when no output file is supplied). The recorder later
    /// copies that temp PNG into the run's `screenshots/` directory.
    private func observeTargetWindow(_ window: CuaWindow, stepNumber: Int) async throws -> CuaObservation {
        let screenshotTempFile = Self.makeTemporaryScreenshotPath(stepNumber: stepNumber)
        return try await cuaDriverClient.getWindowState(
            pid: window.pid,
            windowId: window.windowId,
            query: nil,
            screenshotOutFile: screenshotTempFile
        )
    }

    // MARK: - Action execution

    /// Dispatches a validated driver action to the cua-driver client. Only the
    /// six driver-backed kinds reach here; targeting prefers `element_index`
    /// with a coordinate fallback, matching the contract.
    private func execute(action: MonkeyAction, on window: CuaWindow) async throws {
        switch action.action {
        case .click:
            try await cuaDriverClient.click(
                pid: window.pid,
                windowId: window.windowId,
                elementIndex: action.elementIndex,
                x: action.x,
                y: action.y
            )

        case .type_text:
            try await cuaDriverClient.typeText(
                pid: window.pid,
                windowId: window.windowId,
                elementIndex: action.elementIndex,
                text: action.text ?? ""
            )

        case .set_value:
            // validate() guarantees elementIndex and value are present.
            try await cuaDriverClient.setValue(
                pid: window.pid,
                windowId: window.windowId,
                elementIndex: action.elementIndex ?? 0,
                value: action.value ?? ""
            )

        case .scroll:
            try await cuaDriverClient.scroll(
                pid: window.pid,
                direction: action.direction ?? "down",
                by: action.by ?? "line",
                amount: action.amount ?? 1,
                elementIndex: action.elementIndex,
                windowId: window.windowId
            )

        case .press_key:
            try await cuaDriverClient.pressKey(
                pid: window.pid,
                key: action.key ?? "Return"
            )

        case .hotkey:
            try await cuaDriverClient.hotkey(
                pid: window.pid,
                keys: action.keys ?? []
            )

        case .observe, .wait, .done, .ask_user:
            // Non-driver kinds are handled by the loop, never dispatched here.
            break
        }
    }

    // MARK: - Termination helpers

    private func finishDone(summary: String, recorder: MonkeyTraceRecorder) {
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "done"
        state.lastActionSummary = summary
    }

    private func finishStopped(recorder: MonkeyTraceRecorder) {
        let summary = "Stopped by user after \(state.stepNumber) step(s)."
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "stopped"
        state.lastActionSummary = summary
    }

    private func finishStepLimit(recorder: MonkeyTraceRecorder) {
        let summary = "Reached the step limit of \(maximumStepCount) without completing the task."
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "step limit reached"
        state.lastActionSummary = summary
        // Not a failure (no crash/error) — a terminal non-completion. Leaving
        // failureMessage nil keeps the HUD from showing red "failed" styling.
    }

    private func finishWithFailure(_ message: String, recorder: MonkeyTraceRecorder) {
        recorder.finalize(summary: "Failure: \(message)")
        state.isRunning = false
        state.statusLine = "failed"
        state.lastActionSummary = message
        state.failureMessage = message
    }

    private func surfaceUserQuestion(_ question: String, recorder: MonkeyTraceRecorder) {
        recorder.finalize(summary: "Paused to ask the user: \(question)")
        state.isRunning = false
        state.statusLine = "waiting for user"
        state.lastActionSummary = question
        state.pendingUserQuestion = question
    }

    /// Records a non-fatal/fatal step that lacks a successful action payload.
    private func recordFailureStep(
        stepNumber: Int,
        action: MonkeyAction? = nil,
        summary: String,
        recorder: MonkeyTraceRecorder,
        priorStepRecords: inout [MonkeyStepRecord]
    ) {
        let recordedAction = action ?? Self.bareObserveAction()
        let record = MonkeyStepRecord(
            stepNumber: stepNumber,
            action: recordedAction,
            result: summary,
            verification: nil
        )
        recorder.recordStep(record, observationFile: nil, screenshotFile: nil)
        priorStepRecords.append(record)
        state.lastActionSummary = summary
    }

    // MARK: - Small utilities

    /// Sleeps in short slices so the Stop button interrupts a long `wait` action
    /// promptly instead of blocking for the full duration.
    private func sleep(seconds: Double) async {
        let clamped = max(0, seconds)
        let sliceSeconds = 0.25
        var remaining = clamped
        while remaining > 0 && !stopRequested {
            let thisSlice = min(sliceSeconds, remaining)
            try? await Task.sleep(nanoseconds: UInt64(thisSlice * 1_000_000_000))
            remaining -= thisSlice
        }
    }

    /// Caps the observation markdown to a length budget before it goes to the
    /// model. This is a SIZE cap, not a semantic filter — element_index tags are
    /// preserved up to the cut, and a note tells the model the tree was trimmed
    /// (so it can scroll or narrow rather than assume it saw everything). Keeps
    /// huge Clay tables from blowing up the prompt without hiding elements by
    /// keyword. ~12k chars ≈ a few thousand tokens.
    private static func capObservation(_ markdown: String, limit: Int = 12_000) -> String {
        guard markdown.count > limit else { return markdown }
        let head = String(markdown.prefix(limit))
        return head + "\n\n…[observation truncated to \(limit) characters — scroll to reveal more elements, or narrow the task]"
    }

    /// Keeps only the most recent screenshots (contract: last 1–3) for the model.
    private func trimToRecent(_ paths: [String]) -> [String] {
        guard paths.count > recentScreenshotWindowSize else { return paths }
        return Array(paths.suffix(recentScreenshotWindowSize))
    }

    // MARK: - Formatting / summaries (pure, static)

    /// A placeholder `observe` action used only to populate the non-optional
    /// `action` field of failure step records. Built by decoding a literal we
    /// fully control (`{"action":"observe"}`), so we never depend on a particular
    /// synthesized memberwise-initializer shape for `MonkeyAction`. The decode is
    /// total for this fixed input; the optional fallback keeps it crash-free.
    private static func bareObserveAction() -> MonkeyAction {
        // All payload fields default to nil, so the memberwise init is total —
        // no decoding, no force-try, no possible trap.
        return MonkeyAction(action: .observe)
    }

    /// Deletes a transient temp file (best-effort). Used to clean up the per-step
    /// screenshot PNG once the recorder has copied it into the run directory.
    private static func removeTemporaryFile(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// A unique temp PNG path the driver writes its screenshot to before the
    /// recorder copies it into the run directory. Unique per step + timestamp so
    /// concurrent runs (or retries) never collide.
    private static func makeTemporaryScreenshotPath(stepNumber: Int) -> String {
        let fileName = "monkeybot-step-\(stepNumber)-\(UUID().uuidString).png"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
            .path
    }

    private static func makeTraceSlug(fromTask task: String) -> String {
        let lowered = task.lowercased()
        let allowed = lowered.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(40))
        return trimmed.isEmpty ? "task" : trimmed
    }

    private static func statusLine(for action: MonkeyAction) -> String {
        switch action.action {
        case .click:
            if let index = action.elementIndex { return "clicking [\(index)]" }
            if let pointX = action.x, let pointY = action.y {
                return "clicking (\(Int(pointX)), \(Int(pointY)))"
            }
            return "clicking"
        case .type_text:
            return "typing text"
        case .set_value:
            return "setting value"
        case .scroll:
            return "scrolling \(action.direction ?? "")"
        case .press_key:
            return "pressing \(action.key ?? "key")"
        case .hotkey:
            return "hotkey \((action.keys ?? []).joined(separator: "+"))"
        case .observe:
            return "observing"
        case .wait:
            return "waiting"
        case .done:
            return "done"
        case .ask_user:
            return "asking user"
        }
    }

    private static func actionSummary(for action: MonkeyAction) -> String {
        let base: String
        switch action.action {
        case .click:
            if let index = action.elementIndex {
                base = "click element [\(index)]"
            } else if let pointX = action.x, let pointY = action.y {
                base = "click at (\(Int(pointX)), \(Int(pointY)))"
            } else {
                base = "click"
            }
        case .type_text:
            base = "type \"\(truncate(action.text ?? "", to: 40))\""
        case .set_value:
            base = "set element [\(action.elementIndex ?? -1)] = \"\(truncate(action.value ?? "", to: 40))\""
        case .scroll:
            base = "scroll \(action.direction ?? "") by \(action.by ?? "line") x\(action.amount ?? 1)"
        case .press_key:
            base = "press \(action.key ?? "")"
        case .hotkey:
            base = "hotkey \((action.keys ?? []).joined(separator: "+"))"
        case .observe:
            base = "observe"
        case .wait:
            base = "wait \(format(seconds: action.seconds ?? 1))s"
        case .done:
            base = "done"
        case .ask_user:
            base = "ask user"
        }
        if let reason = action.reason, !reason.isEmpty {
            return "\(base) — \(truncate(reason, to: 80))"
        }
        return base
    }

    /// Cheap post-action delta used as the per-step verification note.
    private static func verificationDelta(before: CuaObservation, after: CuaObservation) -> String {
        let elementDelta = after.elementCount - before.elementCount
        let elementNote: String
        if elementDelta > 0 {
            elementNote = "\(elementDelta) element(s) appeared"
        } else if elementDelta < 0 {
            elementNote = "\(-elementDelta) element(s) disappeared"
        } else {
            elementNote = "element count unchanged (\(after.elementCount))"
        }
        let treeChanged = before.treeMarkdown != after.treeMarkdown
        return treeChanged
            ? "UI changed: \(elementNote)"
            : "UI unchanged: \(elementNote)"
    }

    private static func format(seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }

    private static func truncate(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    private static func describe(_ error: Error) -> String {
        // CuaDriverError / validation errors are CustomStringConvertible and give
        // the cleanest message; everything else falls back to localizedDescription.
        switch error {
        case let cuaError as CuaDriverError:
            return cuaError.description
        case let validationError as MonkeyActionValidationError:
            return validationError.description
        default:
            return error.localizedDescription
        }
    }
}
