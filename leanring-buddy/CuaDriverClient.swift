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
    let bounds: CGRect

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case title
        case pid
        case windowId = "window_id"
        case isOnScreen = "is_on_screen"
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

    init(binaryPath: String) {
        self.binaryPath = binaryPath
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
    private func call(tool: String, json: [String: Any]) async throws -> Data {
        let jsonArgument = try Self.compactJSONString(from: json)
        let result = try await runProcess(arguments: ["call", tool, jsonArgument])

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
    private static func compactJSONString(from json: [String: Any]) throws -> String {
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
    private func runProcess(arguments: [String]) async throws -> ProcessResult {
        let executablePath = binaryPath
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw CuaDriverError.binaryNotFound
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: CuaDriverError.callFailed(
                            tool: arguments.first ?? "cua-driver",
                            stderr: "failed to launch cua-driver: \(error.localizedDescription)"
                        )
                    )
                    return
                }

                // Read both pipes fully before waiting to avoid a deadlock when
                // a child fills an OS pipe buffer.
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let result = ProcessResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )
                continuation.resume(returning: result)
            }
        }
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
