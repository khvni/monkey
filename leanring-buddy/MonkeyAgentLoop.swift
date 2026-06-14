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

    /// Whether the cua `page` (browser/DOM) tool is usable for the CURRENT run.
    ///
    /// Decided ONCE per run by a single cheap `pageGetText` probe after the
    /// target window is selected. When true, observations are ENRICHED with a
    /// CSS-addressable DOM digest and a `click` carrying `css_selector` is routed
    /// through `pageClickElement`. The moment any page-tool call throws, this is
    /// flipped to false and the loop reverts to the verified AX `element_index`
    /// path for the remainder of the run — a page-tool error NEVER ends the run.
    /// It begins false so that, absent a successful probe, behavior is identical
    /// to the v0.2.0 AX-only path.
    private var browserGroundingActive: Bool = false

    /// Sentinel header the loop prepends to enriched observations and the runtime
    /// keys off to decide whether to mention `css_selector` in its prompt. Kept as
    /// a single shared constant so the two files can never drift on the literal.
    /// `nonisolated` so the (non-MainActor) runtime statics can read it without an
    /// actor hop — it is an immutable `String` constant, trivially `Sendable`.
    nonisolated static let domDigestHeader = "# DOM (CSS-addressable)"

    /// Interactive CSS selectors the DOM digest enumerates when browser grounding
    /// is active. Mirrors the contract's interactive set (input/select/button/a/
    /// textarea plus ARIA-role-bearing nodes).
    private static let domDigestSelectors = "input, select, button, a, textarea, [role]"

    /// Attributes requested for each DOM digest element so the model can pick a
    /// stable selector (prefer #id or [aria-label]) and humans can read the row.
    private static let domDigestAttributes = ["id", "name", "aria-label", "type", "placeholder", "role"]

    /// Hard cap on DOM digest rows so a huge page can't blow up the prompt.
    private static let domDigestRowLimit = 60

    /// One-shot note set by `execute(...)` when a guarded page-tool path did
    /// something noteworthy this turn (e.g. a `css_selector` click that fell back
    /// to AX). The loop appends it to the step record's result, then clears it.
    /// Never carries a fatal condition — page-tool failures are always recovered.
    private var pendingStepNote: String? = nil

    /// Feature 3b — whether this run asked the driver to record a cua trajectory.
    /// Set true only after `startRecording` is attempted at run start. Guards the
    /// terminal-path `stopRecording` so we don't issue an unconditional stop for a
    /// run that never tried to record. The stop itself is still best-effort.
    private var cuaRecordingAttempted: Bool = false

    /// Number of screenshots from the most recent observations to keep in the
    /// model's context. Disk retains every artifact; the model only needs the
    /// freshest one to stay grounded without blowing up the prompt.
    private let recentScreenshotWindowSize: Int = 1

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
        // Start every run AX-only; the post-window-select probe may turn this on.
        browserGroundingActive = false
        cuaRecordingAttempted = false

        // Show cua's per-session agent cursor on screen for the whole run, so the
        // user can SEE where Monkey is acting (Clicky-style on-screen feedback).
        // Removed automatically when the run ends, regardless of how it exits.
        await cuaDriverClient.startSession("monkey")
        defer { Task { [cuaDriverClient] in await cuaDriverClient.endSession() } }

        let traceSlug = Self.makeTraceSlug(fromTask: task)
        let traceRecorder = MonkeyTraceRecorder(
            task: task,
            transcript: voiceTranscript,
            slug: traceSlug
        )
        let traceDirectoryPath = traceRecorder.runDirectoryURL.path

        // Feature 3b — OPTIONAL cua trajectory recording. Best-effort and purely
        // additive: this asks the driver to write per-turn cua folders
        // (app_state / screenshot / action.json / click.png) into a
        // `cua-trajectory/` subdirectory of THIS run's trace dir, alongside our
        // own `steps.jsonl`. Video stays OFF by default. If recording is
        // unavailable (older driver, daemon down, missing grant) the `try?`
        // swallows the throw and the run proceeds exactly like v0.2.0 — recording
        // never gates, never ends, and never alters a run. Stopped on EVERY
        // terminal path below.
        let cuaTrajectoryDirectory = traceRecorder.runDirectoryURL
            .appendingPathComponent("cua-trajectory", isDirectory: true)
            .path
        cuaRecordingAttempted = true
        try? await cuaDriverClient.startRecording(
            outputDir: cuaTrajectoryDirectory,
            recordVideo: false
        )

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

        // 1. Find the frontmost user app window (any desktop app) and bring it to front.
        let targetWindow: CuaWindow
        do {
            guard let pickedWindow = try await locateTargetWindow() else {
                await surfaceUserQuestion(
                    "I couldn't find an app window to act on. Open the app you want me to use, bring it to the front, and try again.",
                    recorder: traceRecorder
                )
                return
            }
            targetWindow = pickedWindow
        } catch {
            await finishWithFailure(
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

        // Probe browser/DOM grounding ONCE for this run (a single cheap
        // page.get_text). This is purely additive: if the page tool is
        // unavailable (Apple Events off / Automation TCC missing / older driver)
        // the probe returns false and the entire loop behaves exactly like the
        // v0.2.0 AX `element_index` path. `browserGroundingProbe` never throws.
        browserGroundingActive = await cuaDriverClient.browserGroundingProbe(
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
            await finishWithFailure(
                "Initial observation failed: \(Self.describe(error))",
                recorder: traceRecorder
            )
            return
        }

        // Observation markdown the MODEL sees. When browser grounding is active
        // this is the full AX tree PLUS a CSS-addressable DOM digest; when it is
        // not (the v0.2.0 path) it is exactly the AX `tree_markdown`. The trace
        // recorder always stores the raw AX tree, never the enrichment.
        var currentObservationMarkdownForModel = await enrichedObservationMarkdown(
            axTreeMarkdown: currentObservation.treeMarkdown,
            window: targetWindow
        )

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
                await finishStopped(completedStepCount: priorStepRecords.count, recorder: traceRecorder)
                return
            }

            state.stepNumber = stepNumber
            state.statusLine = "thinking"

            let agentContext = AgentContext(
                task: task,
                voiceTranscript: voiceTranscript,
                targetApplicationName: targetWindow.appName,
                observationMarkdown: Self.capObservation(currentObservationMarkdownForModel),
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
                await finishWithFailure(failureSummary, recorder: traceRecorder)
                return
            }

            if stopRequested {
                await finishStopped(completedStepCount: priorStepRecords.count, recorder: traceRecorder)
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
                await finishDone(summary: summaryText, recorder: traceRecorder)
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
                await surfaceUserQuestion(question, recorder: traceRecorder)
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
                pendingStepNote = nil
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
                    await finishWithFailure(executionSummary, recorder: traceRecorder)
                    return
                }
            }

            if stopRequested {
                await finishStopped(completedStepCount: priorStepRecords.count, recorder: traceRecorder)
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
                await finishWithFailure(observeSummary, recorder: traceRecorder)
                return
            }

            // Refresh the model-facing markdown (AX tree, plus DOM digest when
            // browser grounding is still active). Recorder keeps the raw AX tree.
            currentObservationMarkdownForModel = await enrichedObservationMarkdown(
                axTreeMarkdown: currentObservation.treeMarkdown,
                window: targetWindow
            )

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

            // Fold in any guarded page-tool note (e.g. a css_selector click that
            // fell back to AX) so the trace and the model's history both record it.
            var stepResult = Self.actionSummary(for: decidedAction)
            if let note = pendingStepNote, !note.isEmpty {
                stepResult += " — \(note)"
            }
            pendingStepNote = nil

            let stepRecord = MonkeyStepRecord(
                stepNumber: stepNumber,
                action: decidedAction,
                result: stepResult,
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
        await finishStepLimit(recorder: traceRecorder)
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
    private func locateTargetWindow() async throws -> CuaWindow? {
        let windows = try await cuaDriverClient.listWindows()
        let selfPid = Int(ProcessInfo.processInfo.processIdentifier)
        return Self.selectTargetWindow(from: windows, excludingPid: selfPid)
    }

    /// Pure, side-effect-free window-selection heuristic. App-AGNOSTIC: Monkey is a
    /// desktop computer-use agent (a tier above browser agents), so it targets the
    /// frontmost USER app window — native macOS apps (Notes, System Settings, Mail,
    /// Finder) or a browser — NOT just Chrome.
    ///  1. Exclude our own UI (by pid) and system/menu surfaces — the agent must
    ///     never drive itself.
    ///  2. Keep on-screen windows with a real (non-empty) title that are big enough
    ///     to be an app's main window (drops tiny off-screen helper windows).
    ///  3. Pick the largest such window — the user brings their target app forward
    ///     before speaking, and its main window is the biggest thing on screen.
    ///  4. nil when no suitable app window is found.
    static func selectTargetWindow(from windows: [CuaWindow], excludingPid selfPid: Int = 0) -> CuaWindow? {
        func area(_ window: CuaWindow) -> Double { window.bounds.width * window.bounds.height }

        // Our own app + the driver + system/menu surfaces are never valid targets.
        let excludedApps = ["Monkey", "Clicky", "CuaDriver", "WindowServer", "Window Server",
                            "Dock", "Control Center", "Notification Center", "Spotlight", "Screenshot"]

        let candidates = windows.filter { window in
            window.pid != selfPid
                && window.isOnScreen
                && !window.title.trimmingCharacters(in: .whitespaces).isEmpty
                && !excludedApps.contains(where: { window.appName.localizedCaseInsensitiveContains($0) })
                && area(window) >= 120_000   // ~a real main window, not a helper
        }
        // Frontmost window wins (highest z-index = what the user just had focused);
        // largest area breaks ties. Monkey never steals focus, so the frontmost
        // non-self window is the app the user pointed at before speaking.
        return candidates.sorted { lhs, rhs in
            if lhs.zIndex != rhs.zIndex { return lhs.zIndex > rhs.zIndex }
            return area(lhs) > area(rhs)
        }.first
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

    // MARK: - Browser/DOM grounding (additive enrichment, guarded)

    /// The markdown the MODEL sees for an observation.
    ///
    /// - When `browserGroundingActive` is false (the v0.2.0 path), this returns
    ///   the AX `tree_markdown` UNCHANGED — byte-for-byte identical to before.
    /// - When active, it appends a compact, CSS-addressable DOM digest under the
    ///   shared `# DOM (CSS-addressable)` header so the model can target web
    ///   controls by stable selector. The FULL AX tree is ALWAYS kept first, so
    ///   `element_index` remains valid and the AX path keeps working untouched.
    ///
    /// Resilience: the digest comes from a single best-effort `pageQueryDom`. If
    /// it throws (page tool became unusable mid-run), this DISABLES browser
    /// grounding for the rest of the run and returns just the AX tree — it NEVER
    /// throws and NEVER ends the run.
    private func enrichedObservationMarkdown(
        axTreeMarkdown: String,
        window: CuaWindow
    ) async -> String {
        guard browserGroundingActive else { return axTreeMarkdown }

        let elements: [CuaPageElement]
        do {
            elements = try await cuaDriverClient.pageQueryDom(
                pid: window.pid,
                windowId: window.windowId,
                cssSelector: Self.domDigestSelectors,
                attributes: Self.domDigestAttributes
            )
        } catch {
            // Lost the page tool — revert to AX-only for the remainder of the run.
            browserGroundingActive = false
            return axTreeMarkdown
        }

        let digest = Self.formatDomDigest(elements)
        guard !digest.isEmpty else {
            // Page tool answered but yielded nothing useful; keep AX as the sole
            // grounding this turn (do NOT disable — the probe succeeded).
            return axTreeMarkdown
        }

        // AX tree FIRST (so element_index keeps working), DOM digest appended.
        return axTreeMarkdown + "\n\n" + digest
    }

    /// Render `query_dom` rows into a compact, model-readable digest. Each line is
    /// a CSS-addressable interactive element with its most stable attributes. The
    /// model is told (in the runtime prompt) to prefer #id or [aria-label].
    /// Returns "" when there is nothing addressable to add.
    private static func formatDomDigest(_ elements: [CuaPageElement]) -> String {
        var lines: [String] = []
        for element in elements {
            let line = formatDomDigestRow(element)
            if !line.isEmpty { lines.append(line) }
            if lines.count >= domDigestRowLimit { break }
        }
        guard !lines.isEmpty else { return "" }

        var section = "\(domDigestHeader)\n"
        section += "Interactive web elements addressable by CSS selector (prefer a stable selector like #id or [aria-label]). "
        section += "The accessibility tree above still works via element_index — use whichever is more reliable.\n"
        section += lines.joined(separator: "\n")
        if elements.count > lines.count {
            section += "\n…(\(elements.count - lines.count) more element(s) omitted)"
        }
        return section
    }

    /// One DOM digest line: tag + best stable selector + key attributes + text.
    /// Skips rows that carry no addressable handle at all.
    private static func formatDomDigestRow(_ element: CuaPageElement) -> String {
        let attributes = element.attributes ?? [:]

        // Choose the most stable selector to show: explicit selector, else #id,
        // else [name=…], else [aria-label=…]. Used only for display/guidance —
        // the model still emits its own css_selector.
        let identifier = attributes["id"].flatMap { $0.isEmpty ? nil : "#\($0)" }
        let nameSelector = attributes["name"].flatMap { $0.isEmpty ? nil : "[name=\"\($0)\"]" }
        let ariaSelector = attributes["aria-label"].flatMap { $0.isEmpty ? nil : "[aria-label=\"\($0)\"]" }
        let stableSelector = element.selector
            ?? identifier
            ?? nameSelector
            ?? ariaSelector

        // A row with neither a tag nor any addressable handle is noise — drop it.
        let tag = element.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (tag?.isEmpty == false) || stableSelector != nil else { return "" }

        var parts: [String] = []
        parts.append("- \(tag ?? "node")")
        if let stableSelector { parts.append("selector=\(stableSelector)") }

        for key in ["id", "name", "aria-label", "type", "placeholder", "role"] {
            if let raw = attributes[key], !raw.isEmpty {
                parts.append("\(key)=\"\(truncate(raw, to: 40))\"")
            }
        }

        if let text = element.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            parts.append("text=\"\(truncate(text, to: 40))\"")
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Action execution

    /// Dispatches a validated driver action to the cua-driver client. Only the
    /// six driver-backed kinds reach here; targeting prefers `element_index`
    /// with a coordinate fallback, matching the contract.
    private func execute(action: MonkeyAction, on window: CuaWindow) async throws {
        switch action.action {
        case .click:
            // GUARDED browser/DOM path: only when the model supplied a
            // css_selector AND this run's browser grounding is active. Any failure
            // here is recovered in-place (deactivate + note + fall back) and is
            // NEVER allowed to throw out of execute — that would end the run. The
            // element_index / (x,y) AX paths below are completely unchanged.
            if let cssSelector = action.cssSelector,
               !cssSelector.isEmpty,
               browserGroundingActive {
                do {
                    try await cuaDriverClient.pageClickElement(
                        pid: window.pid,
                        windowId: window.windowId,
                        selector: cssSelector
                    )
                    pendingStepNote = "clicked via page tool (css_selector \(cssSelector))"
                    return
                } catch {
                    // Page tool just became unusable for this run. Disable it,
                    // note the fallback, and recover WITHOUT throwing.
                    browserGroundingActive = false
                    if let elementIndex = action.elementIndex {
                        // The model also gave an AX target — use it now.
                        try await cuaDriverClient.click(
                            pid: window.pid,
                            windowId: window.windowId,
                            elementIndex: elementIndex,
                            x: nil,
                            y: nil
                        )
                        pendingStepNote = "css_selector click failed (\(Self.describe(error))); fell back to AX element_index \(elementIndex)"
                    } else if let pointX = action.x, let pointY = action.y {
                        try await cuaDriverClient.click(
                            pid: window.pid,
                            windowId: window.windowId,
                            elementIndex: nil,
                            x: pointX,
                            y: pointY
                        )
                        pendingStepNote = "css_selector click failed (\(Self.describe(error))); fell back to AX coordinate click"
                    } else {
                        // No AX target this turn: recover by re-observing (the
                        // loop does this unconditionally) so the NEXT turn can use
                        // a fresh element_index. Do not throw.
                        pendingStepNote = "css_selector click failed (\(Self.describe(error))); browser grounding disabled, re-observing for AX element_index next turn"
                    }
                    return
                }
            }

            // AX `element_index` / (x,y) path — IDENTICAL to v0.2.0.
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

    /// Feature 3b — best-effort stop of the optional cua trajectory recording.
    /// Called from EVERY terminal path (done / stop / limit / failure / ask_user).
    /// Only issues a stop when this run actually attempted to start recording, so
    /// we never reach into a recording another client may own. The driver
    /// documents `stop_recording` as a no-op when nothing is recording; the `try?`
    /// additionally swallows any throw so a stop failure is non-fatal.
    private func stopCuaRecordingBestEffort() async {
        guard cuaRecordingAttempted else { return }
        cuaRecordingAttempted = false
        try? await cuaDriverClient.stopRecording()
    }

    private func finishDone(summary: String, recorder: MonkeyTraceRecorder) async {
        await stopCuaRecordingBestEffort()
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "done"
        state.lastActionSummary = summary
    }

    /// `completedStepCount` is the number of steps ACTUALLY recorded (the count of
    /// `priorStepRecords`), not `state.stepNumber`. `state.stepNumber` is advanced
    /// to the in-flight step at the top of each loop iteration before that step is
    /// recorded, so reporting it here would over-count by one whenever the stop is
    /// observed at a loop boundary before the current step landed.
    private func finishStopped(completedStepCount: Int, recorder: MonkeyTraceRecorder) async {
        await stopCuaRecordingBestEffort()
        let summary = "Stopped by user after \(completedStepCount) step(s)."
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "stopped"
        state.lastActionSummary = summary
    }

    private func finishStepLimit(recorder: MonkeyTraceRecorder) async {
        await stopCuaRecordingBestEffort()
        let summary = "Reached the step limit of \(maximumStepCount) without completing the task."
        recorder.finalize(summary: summary)
        state.isRunning = false
        state.statusLine = "step limit reached"
        state.lastActionSummary = summary
        // Not a failure (no crash/error) — a terminal non-completion. Leaving
        // failureMessage nil keeps the HUD from showing red "failed" styling.
    }

    private func finishWithFailure(_ message: String, recorder: MonkeyTraceRecorder) async {
        await stopCuaRecordingBestEffort()
        recorder.finalize(summary: "Failure: \(message)")
        state.isRunning = false
        state.statusLine = "failed"
        state.lastActionSummary = message
        state.failureMessage = message
    }

    private func surfaceUserQuestion(_ question: String, recorder: MonkeyTraceRecorder) async {
        await stopCuaRecordingBestEffort()
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
    static func capObservation(_ markdown: String, limit: Int = 12_000) -> String {
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

    static func makeTraceSlug(fromTask task: String) -> String {
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

    static func statusLine(for action: MonkeyAction) -> String {
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

    static func actionSummary(for action: MonkeyAction) -> String {
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
    static func verificationDelta(before: CuaObservation, after: CuaObservation) -> String {
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

    static func format(seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return String(Int(seconds))
        }
        return String(format: "%.1f", seconds)
    }

    static func truncate(_ text: String, to maxLength: Int) -> String {
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
