//
//  CuaDriverClient.swift
//  leanring-buddy
//
//  Thin Swift wrapper over the installed `cua-driver` CLI (cua-driver 0.5.3).
//  All driver interaction goes through `cua-driver call <tool> '<compact-json>'`,
//  where the JSON arguments are passed as a SINGLE positional argument and the
//  driver replies with a JSON object on stdout. Errors are reported on stderr
//  with a non-zero exit code, which this wrapper surfaces verbatim.
//
//  This file is intentionally self-contained: it shells out via `Process`,
//  decodes the driver's snake_case JSON keys (pid, window_id, element_index,
//  screenshot_out_file, …), and exposes verbose, clearly named observe/act
//  wrappers for the agent loop to call.
//
//  IMPORTANT cua-driver facts encoded here:
//  - Tool names are snake_case: list_windows, get_window_state, click, type_text,
//    set_value, scroll, press_key, hotkey, bring_to_front.
//  - There is NO `wait` tool — the agent loop sleeps client-side instead.
//  - Element-indexed actions require pid + window_id + element_index sourced from
//    the LAST get_window_state snapshot (the index map is replaced every snapshot,
//    so the loop must re-observe every turn before acting).
//  - Read-only tools (list_windows) work without TCC; AX walks and screenshots
//    need Accessibility + Screen Recording grants.
//

import Foundation
import CoreGraphics

// MARK: - Public value types

/// One top-level window as reported by `list_windows`.
/// Mirrors the driver's per-record snake_case fields.
struct CuaWindow: Codable {
    let appName: String
    let title: String
    let pid: Int
    let windowId: Int
    let isOnScreen: Bool
    /// Stacking order from WindowServer — higher = closer to the front.
    let zIndex: Int
    let bounds: CGRect

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case title
        case pid
        case windowId = "window_id"
        case isOnScreen = "is_on_screen"
        case zIndex = "z_index"
        case bounds
    }

    /// The driver renders bounds as a top-left-origin object with x/y/width/height.
    private struct RawBounds: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.appName = try container.decode(String.self, forKey: .appName)
        // Some windows report an empty/absent title — be lenient.
        self.title = (try? container.decode(String.self, forKey: .title)) ?? ""
        self.pid = try container.decode(Int.self, forKey: .pid)
        self.windowId = try container.decode(Int.self, forKey: .windowId)
        self.isOnScreen = (try? container.decode(Bool.self, forKey: .isOnScreen)) ?? false
        self.zIndex = (try? container.decode(Int.self, forKey: .zIndex)) ?? 0
        let rawBounds = try container.decode(RawBounds.self, forKey: .bounds)
        self.bounds = CGRect(
            x: rawBounds.x,
            y: rawBounds.y,
            width: rawBounds.width,
            height: rawBounds.height
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appName, forKey: .appName)
        try container.encode(title, forKey: .title)
        try container.encode(pid, forKey: .pid)
        try container.encode(windowId, forKey: .windowId)
        try container.encode(isOnScreen, forKey: .isOnScreen)
        try container.encode(zIndex, forKey: .zIndex)
        let rawBounds = RawBounds(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.size.width,
            height: bounds.size.height
        )
        try container.encode(rawBounds, forKey: .bounds)
    }
}

/// Result of a `get_window_state` snapshot. The element_index values referenced
/// by `treeMarkdown` are scoped to THIS snapshot only.
struct CuaObservation {
    /// Markdown rendering of the AX tree with `[element_index N]` tags.
    let treeMarkdown: String
    /// Count of actionable elements the driver tagged.
    let elementCount: Int
    /// Path to the PNG screenshot, present when `screenshotOutFile` was requested.
    let screenshotFilePath: String?
}

/// Snapshot of the driver's readiness, suitable for surfacing in a demo HUD.
struct CuaPreflight {
    /// Resolved binary path, or nil if `cua-driver` could not be located.
    let binaryPath: String?
    /// True when the daemon reports as running via `status`.
    let daemonRunning: Bool
    /// "granted" when both Accessibility and Screen Recording are granted,
    /// "denied" when at least one is missing, "unknown" if it could not be read.
    let permissionStatus: String
    /// Human-readable one-liner describing the overall state for the HUD.
    let detail: String
}

enum CuaDriverError: Error, CustomStringConvertible {
    case binaryNotFound
    case callFailed(tool: String, stderr: String)
    case decodeFailed(String)
    case permissionDenied(String)

    var description: String {
        switch self {
        case .binaryNotFound:
            return "cua-driver binary not found. Looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, then PATH. Install CuaDriver or add it to PATH."
        case .callFailed(let tool, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "cua-driver call \(tool) failed: \(trimmed.isEmpty ? "(no stderr)" : trimmed)"
        case .decodeFailed(let detail):
            return "Failed to decode cua-driver response: \(detail)"
        case .permissionDenied(let detail):
            return "cua-driver permission denied: \(detail)"
        }
    }

    var localizedDescription: String { description }
}

// MARK: - Client

@MainActor
final class CuaDriverClient {

    /// Absolute path to the resolved `cua-driver` binary.
    let binaryPath: String

    /// When set, every `call` auto-includes this session id so cua renders its
    /// per-session on-screen agent cursor (visible feedback during an agent run).
    var activeSession: String?

    init(binaryPath: String) {
        self.binaryPath = binaryPath
    }

    /// Declares a cua session (shows the agent cursor) and routes all subsequent
    /// calls through it. Best-effort.
    func startSession(_ id: String) async {
        activeSession = id
        _ = try? await call(tool: "start_session", json: ["session": id])
    }

    /// Ends the active cua session (removes the agent cursor). Best-effort.
    func endSession() async {
        guard let id = activeSession else { return }
        _ = try? await call(tool: "end_session", json: ["session": id])
        activeSession = nil
    }

    // MARK: Binary location (4-path search)

    /// Locate the `cua-driver` binary using the contract's search order:
    /// 1. ~/.local/bin/cua-driver
    /// 2. /opt/homebrew/bin/cua-driver
    /// 3. /usr/local/bin/cua-driver
    /// 4. anything resolvable on PATH (`/usr/bin/env cua-driver`)
    static func locateBinary() -> String? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser.path

        let explicitCandidates = [
            "\(homeDirectory)/.local/bin/cua-driver",
            "/opt/homebrew/bin/cua-driver",
            "/usr/local/bin/cua-driver"
        ]

        for candidate in explicitCandidates {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 4th path: resolve via the user's PATH using `/usr/bin/env`.
        if let resolved = resolveOnPath() {
            return resolved
        }

        return nil
    }

    /// Ask `/usr/bin/env` to resolve `cua-driver` against the inherited PATH.
    /// Returns the absolute path on success, nil otherwise.
    private static func resolveOnPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "cua-driver"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    // MARK: Preflight + doctor (demo-friendly, user-visible)

    /// Demo-friendly readiness check. Combines:
    /// - binary presence (already resolved at init),
    /// - the daemon `status` subcommand (plain-text "running" report),
    /// - `permissions status --json` (Accessibility + Screen Recording booleans).
    /// Never throws — always returns a populated `CuaPreflight` for the HUD.
    func preflight() async -> CuaPreflight {
        // The binary exists because this instance was constructed with a path,
        // but re-confirm so a deleted/relocated binary is reported cleanly.
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            return CuaPreflight(
                binaryPath: nil,
                daemonRunning: false,
                permissionStatus: "unknown",
                detail: "cua-driver binary missing at \(binaryPath)."
            )
        }

        let daemonRunning = await checkDaemonRunning()
        let (permissionStatus, permissionDetail) = await checkPermissions()

        let detail: String
        if !daemonRunning {
            detail = "cua-driver found, but the daemon is not running. Read-only window listing still works; AX actions and screenshots need the daemon."
        } else if permissionStatus == "granted" {
            detail = "Ready: daemon running, Accessibility + Screen Recording granted."
        } else if permissionStatus == "denied" {
            detail = "Daemon running, but \(permissionDetail) Grant via System Settings or `cua-driver permissions grant`."
        } else {
            detail = "Daemon running; permission status could not be read (\(permissionDetail))."
        }

        return CuaPreflight(
            binaryPath: binaryPath,
            daemonRunning: daemonRunning,
            permissionStatus: permissionStatus,
            detail: detail
        )
    }

    /// Run the driver's `status` subcommand and detect the "running" report.
    /// `status` prints plain text (not JSON), e.g. "Cua Driver daemon is running".
    private func checkDaemonRunning() async -> Bool {
        guard let result = try? await runProcess(arguments: ["status"]) else {
            return false
        }
        let combined = (result.stdout + "\n" + result.stderr).lowercased()
        // Treat an explicit "not running" as down; otherwise require "running".
        if combined.contains("not running") { return false }
        return result.exitCode == 0 && combined.contains("running")
    }

    /// Read `permissions status --json` and collapse it into granted/denied/unknown.
    private func checkPermissions() async -> (status: String, detail: String) {
        guard let result = try? await runProcess(arguments: ["permissions", "status", "--json"]),
              let data = result.stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("unknown", "permissions status --json was unreadable.")
        }

        let accessibility = (object["accessibility"] as? Bool) ?? false
        let screenRecording = (object["screen_recording"] as? Bool) ?? false

        if accessibility && screenRecording {
            return ("granted", "all grants present.")
        }

        var missing: [String] = []
        if !accessibility { missing.append("Accessibility") }
        if !screenRecording { missing.append("Screen Recording") }
        let missingList = missing.joined(separator: " + ")
        return ("denied", "\(missingList) permission is missing.")
    }

    /// Verbose diagnostic dump from the driver's `doctor` subcommand, plus the
    /// resolved binary path. Useful to print in a demo when something is off.
    func doctor() async -> String {
        var report = "cua-driver binary: \(binaryPath)\n"
        guard let result = try? await runProcess(arguments: ["doctor"]) else {
            report += "doctor: failed to invoke cua-driver doctor."
            return report
        }
        let body = result.stdout.isEmpty ? result.stderr : result.stdout
        report += body.trimmingCharacters(in: .whitespacesAndNewlines)
        return report
    }

    // MARK: Observe

    /// `list_windows` — every layer-0 top-level window known to WindowServer.
    /// Read-only; works without the daemon/TCC.
    func listWindows() async throws -> [CuaWindow] {
        let data = try await call(tool: "list_windows", json: [:])
        return try Self.decodeWindows(from: data)
    }

    /// Pure, side-effect-free decode of a `list_windows` response payload into
    /// `[CuaWindow]`. Extracted so the wire decoding can be asserted directly in
    /// tests without shelling out to the driver. Throws `CuaDriverError.decodeFailed`
    /// on a malformed payload, matching `listWindows()`'s original behavior.
    static func decodeWindows(from data: Data) throws -> [CuaWindow] {
        do {
            let envelope = try JSONDecoder().decode(ListWindowsEnvelope.self, from: data)
            return envelope.windows
        } catch {
            throw CuaDriverError.decodeFailed("list_windows: \(error)")
        }
    }

    /// `get_window_state` — walk the app's AX tree, returning Markdown tagged with
    /// `[element_index N]` plus a screenshot. Pass `screenshotOutFile` to write the
    /// PNG to disk (otherwise the driver embeds base64, which we intentionally avoid).
    ///
    /// INVARIANT: the returned element indices are valid only until the NEXT
    /// snapshot of the same (pid, window_id). Re-observe every turn before acting.
    func getWindowState(
        pid: Int,
        windowId: Int,
        query: String?,
        screenshotOutFile: String?
    ) async throws -> CuaObservation {
        var arguments: [String: Any] = [
            "pid": pid,
            "window_id": windowId
        ]
        if let query, !query.isEmpty {
            arguments["query"] = query
        }
        // `som` = AX walk + screenshot (the default). Request a file path so the
        // response carries `screenshot_file_path` instead of inline base64.
        if let screenshotOutFile, !screenshotOutFile.isEmpty {
            arguments["screenshot_out_file"] = screenshotOutFile
            arguments["capture_mode"] = "som"
        } else {
            // No screenshot requested → AX-only walk keeps the payload small.
            arguments["capture_mode"] = "ax"
        }

        let data = try await call(tool: "get_window_state", json: arguments)
        do {
            let raw = try JSONDecoder().decode(GetWindowStateResponse.self, from: data)
            return CuaObservation(
                treeMarkdown: raw.treeMarkdown,
                elementCount: raw.elementCount,
                screenshotFilePath: raw.screenshotFilePath
            )
        } catch {
            throw CuaDriverError.decodeFailed("get_window_state: \(error)")
        }
    }

    // MARK: Act

    /// `bring_to_front` — on macOS the driver stubs this out (CGEvent posting
    /// reaches backgrounded windows without activation), returning an error that
    /// points at NSRunningApplication.activate. We call it best-effort and
    /// swallow that expected platform error so the loop can proceed.
    func bringToFront(pid: Int, windowId: Int) async throws {
        let arguments: [String: Any] = [
            "pid": pid,
            "window_id": windowId
        ]
        do {
            _ = try await call(tool: "bring_to_front", json: arguments)
        } catch CuaDriverError.callFailed {
            // Expected no-op on macOS — input tools reach backgrounded windows.
            return
        }
    }

    /// `click` — prefer `elementIndex` (+ windowId) AX path; fall back to window-
    /// local screenshot pixel coordinates (x, y) only when there is no AX target
    /// (canvas / video / WebGL surfaces). element_index requires window_id.
    func click(
        pid: Int,
        windowId: Int?,
        elementIndex: Int?,
        x: Double?,
        y: Double?
    ) async throws {
        var arguments: [String: Any] = ["pid": pid]

        if let elementIndex {
            arguments["element_index"] = elementIndex
            if let windowId {
                arguments["window_id"] = windowId
            }
        } else if let x, let y {
            arguments["x"] = x
            arguments["y"] = y
            if let windowId {
                arguments["window_id"] = windowId
            }
        }
        // If neither an index nor coordinates were supplied, the driver decides
        // (e.g. clicks the cursor's current position); we pass pid only.

        _ = try await call(tool: "click", json: arguments)
    }

    /// `type_text` — insert text at the target's cursor. With `elementIndex`
    /// (+ windowId) the write is directed at a specific field; without it the
    /// write goes to the pid's currently focused element.
    func typeText(
        pid: Int,
        windowId: Int?,
        elementIndex: Int?,
        text: String
    ) async throws {
        var arguments: [String: Any] = [
            "pid": pid,
            "text": text
        ]
        if let elementIndex {
            arguments["element_index"] = elementIndex
            // element_index requires window_id per the schema.
            if let windowId {
                arguments["window_id"] = windowId
            }
        }
        _ = try await call(tool: "type_text", json: arguments)
    }

    /// `set_value` — set a value on a UI element (popup option pick / AXValue write).
    /// Requires pid + window_id + element_index + value.
    func setValue(
        pid: Int,
        windowId: Int,
        elementIndex: Int,
        value: String
    ) async throws {
        let arguments: [String: Any] = [
            "pid": pid,
            "window_id": windowId,
            "element_index": elementIndex,
            "value": value
        ]
        _ = try await call(tool: "set_value", json: arguments)
    }

    /// `scroll` — scroll the focused region via synthesized arrow/page keystrokes.
    /// Optional `elementIndex` (+ windowId) pre-focuses the element first.
    func scroll(
        pid: Int,
        direction: String,
        by: String,
        amount: Int,
        elementIndex: Int?,
        windowId: Int?
    ) async throws {
        var arguments: [String: Any] = [
            "pid": pid,
            "direction": direction,
            "by": by,
            "amount": amount
        ]
        if let elementIndex {
            arguments["element_index"] = elementIndex
            if let windowId {
                arguments["window_id"] = windowId
            }
        }
        _ = try await call(tool: "scroll", json: arguments)
    }

    /// `press_key` — press and release a single key, delivered to the target pid.
    /// Key names: return, tab, escape, up/down/left/right, space, etc.
    func pressKey(pid: Int, key: String) async throws {
        let arguments: [String: Any] = [
            "pid": pid,
            "key": key
        ]
        _ = try await call(tool: "press_key", json: arguments)
    }

    /// `hotkey` — press a combination of keys simultaneously, e.g. ["cmd", "c"].
    /// The combo is posted directly to the pid's event queue (no frontmost needed).
    func hotkey(pid: Int, keys: [String]) async throws {
        let arguments: [String: Any] = [
            "pid": pid,
            "keys": keys
        ]
        _ = try await call(tool: "hotkey", json: arguments)
    }

    // MARK: Core

    /// Run `cua-driver call <tool> '<compact-json>'` with the JSON encoded as a
    /// SINGLE positional argument, returning the raw stdout bytes for decoding.
    /// Throws `CuaDriverError.callFailed` (surfacing stderr) on a non-zero exit.
    private func call(tool: String, json: [String: Any], timeout: TimeInterval = 30) async throws -> Data {
        var json = json
        if let activeSession, json["session"] == nil { json["session"] = activeSession }
        let jsonArgument = try Self.compactJSONString(from: json)
        let result = try await runProcess(arguments: ["call", tool, jsonArgument], timeout: timeout)

        guard result.exitCode == 0 else {
            // Driver reports failures on stderr with a non-zero exit. Fall back to
            // stdout if stderr happened to be empty so the error is never blank.
            let message = result.stderr.isEmpty ? result.stdout : result.stderr
            // A permissions-shaped failure gets a clearer error type.
            let lowered = message.lowercased()
            if lowered.contains("permission") || lowered.contains("not authorized") || lowered.contains("accessibility") {
                throw CuaDriverError.permissionDenied(message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            throw CuaDriverError.callFailed(tool: tool, stderr: message)
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw CuaDriverError.decodeFailed("\(tool): stdout was not valid UTF-8")
        }
        return data
    }

    /// Serialize a `[String: Any]` argument dictionary into a compact JSON string
    /// (no pretty-printing, sorted keys for deterministic output).
    static func compactJSONString(from json: [String: Any]) throws -> String {
        // An empty argument set is still valid JSON: "{}".
        if json.isEmpty { return "{}" }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: json,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            guard let string = String(data: data, encoding: .utf8) else {
                throw CuaDriverError.decodeFailed("could not encode JSON arguments as UTF-8")
            }
            return string
        } catch let error as CuaDriverError {
            throw error
        } catch {
            throw CuaDriverError.decodeFailed("could not serialize JSON arguments: \(error)")
        }
    }

    /// Captured result of a finished subprocess.
    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Launch the resolved `cua-driver` binary with the given arguments and wait
    /// for it to exit, capturing stdout/stderr. Runs the blocking `Process` work
    /// off the main actor so the UI stays responsive.
    ///
    /// Robustness (all three matter for the agent loop + Stop button):
    ///  - Both pipes are drained on SEPARATE threads concurrently with
    ///    waitUntilExit(). Reading them sequentially deadlocks once the child
    ///    fills one OS pipe buffer (~64KB) — cua emits large AX trees on stdout
    ///    and verbose WARN logs on stderr, so this is a real hazard.
    ///  - Task cancellation (user Stop) terminates the running subprocess.
    ///  - A timeout watchdog terminates a wedged call (e.g. a daemon stuck on a
    ///    TCC prompt) so the loop never hangs forever.
    private func runProcess(arguments: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        let executablePath = binaryPath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CuaDriverError.binaryNotFound
        }

        let toolLabel = arguments.count > 1 ? arguments[1] : (arguments.first ?? "cua-driver")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let runGuard = ProcessRunGuard()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                // Watchdog: terminate + fail if the call outlives the timeout.
                let timeoutItem = DispatchWorkItem {
                    if runGuard.launched && process.isRunning { process.terminate() }
                    if runGuard.claimResume() {
                        continuation.resume(throwing: CuaDriverError.callFailed(
                            tool: toolLabel,
                            stderr: "timed out after \(Int(timeout))s"
                        ))
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        timeoutItem.cancel()
                        if runGuard.claimResume() {
                            continuation.resume(throwing: CuaDriverError.callFailed(
                                tool: toolLabel,
                                stderr: "failed to launch cua-driver: \(error.localizedDescription)"
                            ))
                        }
                        return
                    }
                    runGuard.markLaunched()

                    // Drain both pipes on their own threads, concurrently with the
                    // wait, so a full buffer on either stream can never deadlock.
                    var stdoutData = Data()
                    var stderrData = Data()
                    let drainGroup = DispatchGroup()
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }
                    drainGroup.enter()
                    DispatchQueue.global().async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        drainGroup.leave()
                    }

                    process.waitUntilExit()
                    drainGroup.wait()
                    timeoutItem.cancel()

                    if runGuard.claimResume() {
                        continuation.resume(returning: ProcessResult(
                            exitCode: process.terminationStatus,
                            stdout: String(decoding: stdoutData, as: UTF8.self),
                            stderr: String(decoding: stderrData, as: UTF8.self)
                        ))
                    }
                }
            }
        } onCancel: {
            // User pressed Stop (or the parent Task was cancelled): kill the child.
            if runGuard.launched && process.isRunning { process.terminate() }
        }
    }
}

/// Thread-safe one-shot guard shared by the timeout watchdog, the cancellation
/// handler, and the normal completion path so the continuation resumes exactly
/// once and `terminate()` is only called on a launched process.
private final class ProcessRunGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false
    private var didLaunch = false

    func markLaunched() { lock.lock(); didLaunch = true; lock.unlock() }

    var launched: Bool { lock.lock(); defer { lock.unlock() }; return didLaunch }

    /// Returns true exactly once — the caller that wins may resume the continuation.
    func claimResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if hasResumed { return false }
        hasResumed = true
        return true
    }
}

// MARK: - Private wire types

/// `list_windows` response envelope: `{ "windows": [...], "current_space_id": ... }`.
private struct ListWindowsEnvelope: Codable {
    let windows: [CuaWindow]
}

/// `get_window_state` response: snake_case keys produced by the driver.
private struct GetWindowStateResponse: Codable {
    let treeMarkdown: String
    let elementCount: Int
    let screenshotFilePath: String?

    enum CodingKeys: String, CodingKey {
        case treeMarkdown = "tree_markdown"
        case elementCount = "element_count"
        case screenshotFilePath = "screenshot_file_path"
    }
}

// MARK: - Feature 2a: Browser/DOM grounding via the cua `page` tool
//
// The `page` tool drives the browser page loaded in a running app. On
// Chrome/macOS this goes through AppleScript, which has TWO hard prerequisites
// that the core AX demo path does NOT need:
//   1. Chrome's "Allow JavaScript from Apple Events" pref must be on, and
//   2. an Automation TCC grant must let cua-driver send events to Chrome.
// When either is missing, every page action fails. These wrappers DETECT that
// shape of failure in stderr and rethrow it as `CuaPageError.unavailable`, the
// loop's signal to silently fall back to the verified AX `element_index` path.
//
// GOLDEN RULE: every call here is a bonus that degrades to AX. Callers MUST be
// prepared to catch (try?/do-catch) and continue — a page error never ends a run.
//
// JSON key mapping for `cua-driver call page '<json>'` (verified against the
// page tool's input_schema): action, pid, window_id, css_selector (query_dom),
// selector (click_element), attributes ([String] for query_dom).

/// One element returned by the `page` tool's `query_dom` action.
///
/// Shape is best-effort: the driver renders matching DOM nodes and (when
/// `attributes` were requested) their attribute map. All fields are optional so
/// a partial / differently-shaped row never fails the whole decode — a missing
/// field simply decodes to nil rather than throwing, which keeps DOM enrichment
/// resilient (the loop can still fall back to AX).
struct CuaPageElement: Codable {
    /// CSS-addressable selector for the node (e.g. "#sheet-url"), when present.
    let selector: String?
    /// Lowercased tag name (e.g. "input", "select", "button", "a"), when present.
    let tag: String?
    /// Visible/text content of the node, when present.
    let text: String?
    /// Requested attributes (id/name/aria-label/…) keyed by attribute name.
    let attributes: [String: String]?

    enum CodingKeys: String, CodingKey {
        case selector
        case tag
        case text
        case attributes
    }

    init(selector: String?, tag: String?, text: String?, attributes: [String: String]?) {
        self.selector = selector
        self.tag = tag
        self.text = text
        self.attributes = attributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selector = try? container.decodeIfPresent(String.self, forKey: .selector)
        self.tag = try? container.decodeIfPresent(String.self, forKey: .tag)
        self.text = try? container.decodeIfPresent(String.self, forKey: .text)
        // Attribute values arrive as strings; tolerate absence or a non-string map.
        self.attributes = try? container.decodeIfPresent([String: String].self, forKey: .attributes)
    }
}

/// Raised when the `page` tool is unusable in this environment — specifically
/// when Chrome's "Allow JavaScript from Apple Events" is off or the Automation
/// TCC grant is missing. Callers treat this as "no browser grounding available"
/// and fall back to the AX `element_index` path. The associated string carries
/// the driver's stderr for logging.
enum CuaPageError: Error, CustomStringConvertible {
    case unavailable(String)

    var description: String {
        switch self {
        case .unavailable(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "cua page tool unavailable (Apple Events / Automation / JS-from-Apple-Events not enabled): \(trimmed.isEmpty ? "(no detail)" : trimmed)"
        }
    }

    var localizedDescription: String { description }
}

extension CuaDriverClient {

    /// `page` action `get_text` — extract the page's visible text for the target
    /// app window. Used by `browserGroundingProbe` as the cheapest availability
    /// check, and as a coarse text read.
    ///
    /// Throws `CuaPageError.unavailable` when the driver reports an Apple Events /
    /// Automation / JS-from-Apple-Events failure (caller falls back to AX); any
    /// other error is rethrown as the underlying `CuaDriverError`.
    func pageGetText(pid: Int, windowId: Int?) async throws -> String {
        var arguments: [String: Any] = [
            "action": "get_text",
            "pid": pid
        ]
        if let windowId {
            arguments["window_id"] = windowId
        }

        let data = try await callPage(arguments: arguments)

        // The driver returns the extracted text under a few plausible keys
        // depending on version; accept any, else fall back to the raw payload.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["text", "result", "value", "output"] {
                if let string = object[key] as? String { return string }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `page` action `query_dom` — find elements matching `cssSelector`, including
    /// the requested `attributes` in each result. Maps to the page tool's
    /// `css_selector` + `attributes` keys.
    ///
    /// Returns `[CuaPageElement]` (best-effort decode; a non-array payload yields
    /// an empty array rather than throwing). Throws `CuaPageError.unavailable`
    /// when the page tool is not usable so the caller falls back to AX.
    func pageQueryDom(
        pid: Int,
        windowId: Int?,
        cssSelector: String,
        attributes: [String]
    ) async throws -> [CuaPageElement] {
        var arguments: [String: Any] = [
            "action": "query_dom",
            "pid": pid,
            "css_selector": cssSelector
        ]
        if let windowId {
            arguments["window_id"] = windowId
        }
        if !attributes.isEmpty {
            arguments["attributes"] = attributes
        }

        let data = try await callPage(arguments: arguments)
        return Self.decodePageElements(from: data)
    }

    /// `page` action `click_element` — click the element matched by `selector`,
    /// animating the agent cursor to its on-screen center first (visible feedback).
    /// Maps to the page tool's `selector` key.
    ///
    /// Throws `CuaPageError.unavailable` when the page tool is not usable so the
    /// caller can re-observe and fall back to an AX `element_index` click.
    func pageClickElement(pid: Int, windowId: Int?, selector: String) async throws {
        var arguments: [String: Any] = [
            "action": "click_element",
            "pid": pid,
            "selector": selector
        ]
        if let windowId {
            arguments["window_id"] = windowId
        }
        _ = try await callPage(arguments: arguments)
    }

    /// One cheap `page.get_text` to decide whether browser grounding is usable in
    /// this environment, cached per (pid, window_id) so the loop probes ONCE per
    /// run. Returns `true` only when the page tool answered without an Apple
    /// Events / Automation / JS failure; any failure (including a transient
    /// `CuaDriverError`) returns `false` so the loop runs AX-only. Never throws.
    func browserGroundingProbe(pid: Int, windowId: Int?) async -> Bool {
        let cacheKey = Self.groundingCacheKey(pid: pid, windowId: windowId)
        if let cached = Self.browserGroundingCache[cacheKey] {
            return cached
        }
        let available: Bool
        do {
            _ = try await pageGetText(pid: pid, windowId: windowId)
            available = true
        } catch {
            // CuaPageError.unavailable OR any other failure → grounding is off.
            available = false
        }
        Self.browserGroundingCache[cacheKey] = available
        return available
    }

    // MARK: page tool internals

    /// Invoke `cua-driver call page '<json>'`, translating the page tool's
    /// "browser not reachable" failures into `CuaPageError.unavailable` so callers
    /// fall back to AX. The base `call(tool:json:)` already classifies some
    /// stderr as `CuaDriverError.permissionDenied` (it matches "permission" /
    /// "not authorized" / "accessibility") and the rest as `.callFailed`; we
    /// inspect BOTH for the page-specific signatures below and rethrow as
    /// `.unavailable`. Anything we can't attribute to the browser pathway is
    /// rethrown unchanged.
    private func callPage(arguments: [String: Any]) async throws -> Data {
        do {
            // Page calls go through AppleScript and can hang if the browser is
            // wedged; cap them well under the 30s AX default so the loop falls
            // back to the verified AX path fast (esp. the run-start probe).
            return try await call(tool: "page", json: arguments, timeout: 8)
        } catch let error as CuaDriverError {
            switch error {
            case .callFailed(_, let stderr):
                if Self.isPageUnavailable(stderr) {
                    throw CuaPageError.unavailable(stderr)
                }
                throw error
            case .permissionDenied(let detail):
                // An Automation TCC denial is reported as a permission failure;
                // for the page tool that means "use AX instead", not a hard stop.
                if Self.isPageUnavailable(detail) {
                    throw CuaPageError.unavailable(detail)
                }
                throw error
            case .binaryNotFound, .decodeFailed:
                throw error
            }
        }
    }

    /// Detect the page tool's "browser not reachable / scripting not enabled"
    /// failure shapes in driver stderr. Matching is case-insensitive substring so
    /// it survives minor wording changes across driver versions.
    private static func isPageUnavailable(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let signatures = [
            "apple event",          // "Apple Events", "Apple Event"
            "appleevent",
            "not authorized",       // Automation TCC denial
            "automation",           // "Automation" permission wording
            "not allowed to send",  // AppleScript -1743 phrasing
            "-1743",                // errAEEventNotPermitted
            "javascript",           // "Allow JavaScript from Apple Events" off
            "execute javascript",
            "apple events is not enabled",
            "scripting is not enabled",
            "allow javascript"
        ]
        return signatures.contains { lowered.contains($0) }
    }

    /// Best-effort decode of a `query_dom` response into `[CuaPageElement]`.
    /// Accepts several plausible payload shapes (a bare array, or an object with
    /// an `elements` / `results` / `matches` array) so DOM enrichment is robust
    /// across driver versions. A shape we don't recognize yields `[]` — never a
    /// throw — keeping the caller on a clean AX fallback.
    private static func decodePageElements(from data: Data) -> [CuaPageElement] {
        let decoder = JSONDecoder()

        // 1) Bare array of elements.
        if let elements = try? decoder.decode([CuaPageElement].self, from: data) {
            return elements
        }

        // 2) Object wrapping an array under a known key.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        for key in ["elements", "results", "matches", "nodes", "result"] {
            guard let nested = object[key] else { continue }
            if let nestedData = try? JSONSerialization.data(withJSONObject: nested),
               let elements = try? decoder.decode([CuaPageElement].self, from: nestedData) {
                return elements
            }
        }
        return []
    }

    // MARK: grounding probe cache

    /// Probe results keyed by "pid:windowId" (windowId omitted → "pid:any").
    /// `@MainActor` (the whole client is) makes this static mutable state safe.
    private static var browserGroundingCache: [String: Bool] = [:]

    private static func groundingCacheKey(pid: Int, windowId: Int?) -> String {
        if let windowId { return "\(pid):\(windowId)" }
        return "\(pid):any"
    }

    /// Clear the cached browser-grounding probe results so the next run re-probes
    /// from scratch. Called when the user may have toggled Chrome's "Allow
    /// JavaScript from Apple Events" mid-session — without this, a cached `false`
    /// from an earlier probe would keep the loop AX-only even after grounding
    /// became available.
    static func resetBrowserGroundingCache() {
        browserGroundingCache.removeAll()
    }
}

// MARK: - Feature 3b: Optional cua trajectory recording (best-effort wrappers)
//
// These wrap the driver's `start_recording` / `stop_recording` tools so the
// agent loop can OPTIONALLY capture a cua trajectory (per-turn app_state /
// screenshot / action.json / click.png folders) alongside its own steps.jsonl.
//
// BEST-EFFORT semantics — callers invoke these with `try?` and IGNORE failures:
//   - `try? await startRecording(outputDir: runDir/"cua-trajectory", recordVideo: false)` at run start.
//   - `try? await stopRecording()` on EVERY terminal path (done / stop / limit / error).
// If recording is unavailable (older driver, missing grant, daemon down) the
// call throws and the caller's `try?` swallows it — the run continues identically
// to v0.2.0. Recording NEVER gates or ends a run; video stays OFF by default.
//
// JSON key mapping (verified against start_recording input_schema):
//   output_dir (String, required), record_video (Bool, default false).

extension CuaDriverClient {

    /// `start_recording` — begin trajectory recording into `outputDir`. Every
    /// subsequent action-tool call (click/type_text/set_value/scroll/press_key/
    /// hotkey/…) writes a `turn-NNNNN/` folder there. Video is OFF unless
    /// `recordVideo` is true (macOS uses ScreenCaptureKit, needs macOS 15+).
    ///
    /// BEST-EFFORT: call with `try?`. Throwing here must never end a run — the
    /// loop falls back to its own `steps.jsonl` trace and continues unchanged.
    func startRecording(outputDir: String, recordVideo: Bool) async throws {
        let arguments: [String: Any] = [
            "output_dir": outputDir,
            "record_video": recordVideo
        ]
        _ = try await call(tool: "start_recording", json: arguments)
    }

    /// `stop_recording` — disable per-turn capture and finalize any mp4. The
    /// driver documents this as UNCONDITIONAL (stops whatever recording is active)
    /// and a no-op when nothing is recording, so it is safe to call on every
    /// terminal path even if `startRecording` was never reached or failed.
    ///
    /// BEST-EFFORT: call with `try?`. A failure here is non-fatal.
    func stopRecording() async throws {
        _ = try await call(tool: "stop_recording", json: [:])
    }
}
