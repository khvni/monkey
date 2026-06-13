//
//  MonkeyTraceRecorder.swift
//  leanring-buddy
//
//  Persists each Monkeybot agent run to disk so a demo (or a post-mortem)
//  can replay exactly what the agent saw and did. One run = one directory
//  under `~/Documents/Monkeybot/runs/<timestamp>-<slug>/` containing:
//
//      task.txt            — the task the agent was asked to accomplish
//      transcript.txt      — the raw voice transcript that produced the task
//      steps.jsonl         — one JSON-encoded MonkeyStepRecord per line, appended per step
//      final_summary.md    — the agent's closing summary (written on finalize)
//      observations/NN.md  — the pruned get_window_state markdown for step NN
//      screenshots/NN.png  — the screenshot the agent saw for step NN
//
//  References MonkeyStepRecord (AgentRuntime.swift) and MonkeyAction (MonkeyAction.swift).
//  Kept deliberately cheap: writes are best-effort and never throw into the agent loop.
//

import Foundation
import AppKit

/// Records a single Monkeybot run to a timestamped directory on disk.
///
/// All write methods are best-effort: failures are logged to the console but never
/// propagated, so a disk hiccup can never abort the live agent loop. The recorder
/// owns its run directory for its entire lifetime.
@MainActor
final class MonkeyTraceRecorder {

    // MARK: - Stored Layout

    /// Absolute URL of this run's directory, e.g. `…/runs/2026-06-13T19-04-22Z-book-a-table/`.
    private let runDirectory: URL

    /// `runDirectory/observations`, created lazily on first observation.
    private let observationsDirectory: URL

    /// `runDirectory/screenshots`, created lazily on first screenshot.
    private let screenshotsDirectory: URL

    /// `runDirectory/steps.jsonl`. Appended to one line at a time.
    private let stepsJSONLURL: URL

    /// JSON encoder for MonkeyStepRecord. Compact (no pretty-printing) so each
    /// record stays on exactly one line — `.jsonl` requires single-line records.
    private let stepEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()

    // MARK: - Initialization

    /// Creates the run directory under the resolved `runs/` base and writes the
    /// task and transcript files immediately.
    ///
    /// - Parameters:
    ///   - task: The task the agent will attempt. Persisted to `task.txt`.
    ///   - transcript: The raw voice transcript behind the task. Persisted to `transcript.txt`.
    ///   - slug: A short, human-readable, filesystem-safe-ish label for the run. Sanitized
    ///           before use so callers do not have to pre-clean it.
    ///   - baseDirectoryOverride: Test-only injection point for the `runs/` base directory.
    ///           When non-nil it is used verbatim as the base (and created if missing),
    ///           letting tests write into a temp dir. When nil (the default, and the
    ///           only value production ever passes) resolution is unchanged: the
    ///           `MONKEYBOT_RUNS_DIR` env var if set, else `~/Documents/Monkeybot/runs`.
    init(task: String, transcript: String, slug: String, baseDirectoryOverride: URL? = nil) {
        let runsBaseDirectory = MonkeyTraceRecorder.resolveRunsBaseDirectory(override: baseDirectoryOverride)
        let timestamp = MonkeyTraceRecorder.makeTimestampComponent()
        let safeSlug = MonkeyTraceRecorder.sanitizeSlug(slug)

        let directoryName = safeSlug.isEmpty ? timestamp : "\(timestamp)-\(safeSlug)"
        let resolvedRunDirectory = runsBaseDirectory.appendingPathComponent(directoryName, isDirectory: true)

        self.runDirectory = resolvedRunDirectory
        self.observationsDirectory = resolvedRunDirectory.appendingPathComponent("observations", isDirectory: true)
        self.screenshotsDirectory = resolvedRunDirectory.appendingPathComponent("screenshots", isDirectory: true)
        self.stepsJSONLURL = resolvedRunDirectory.appendingPathComponent("steps.jsonl", isDirectory: false)

        MonkeyTraceRecorder.createDirectoryIfMissing(resolvedRunDirectory)

        writeTextFile(named: "task.txt", contents: task)
        writeTextFile(named: "transcript.txt", contents: transcript)
    }

    // MARK: - Public Accessors

    /// Absolute URL of this run's directory. Used by the HUD to show / reveal the trace.
    var runDirectoryURL: URL {
        runDirectory
    }

    // MARK: - Recording

    /// Writes the pruned observation markdown for a step to `observations/NN.md`.
    ///
    /// - Returns: The path of the observation file relative to the run directory
    ///            (e.g. `observations/03.md`), suitable for embedding in a step record.
    @discardableResult
    func recordObservation(stepNumber: Int, markdown: String) -> String {
        MonkeyTraceRecorder.createDirectoryIfMissing(observationsDirectory)

        let fileName = "\(MonkeyTraceRecorder.zeroPadded(stepNumber)).md"
        let destinationURL = observationsDirectory.appendingPathComponent(fileName, isDirectory: false)
        let relativePath = "observations/\(fileName)"

        do {
            try markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[MonkeyTraceRecorder] Failed to write observation \(relativePath): \(error.localizedDescription)")
        }

        return relativePath
    }

    /// Copies (or compresses) a screenshot the agent saw into `screenshots/NN.png`.
    ///
    /// If `sourcePath` is a PNG it is copied verbatim (cheapest path). Otherwise the
    /// image is decoded and re-encoded as PNG so the run directory stays uniform.
    ///
    /// - Parameters:
    ///   - sourcePath: Absolute path of the source screenshot, or nil if the step had none.
    ///   - stepNumber: The step this screenshot belongs to.
    /// - Returns: The screenshot path relative to the run directory (e.g. `screenshots/03.png`),
    ///            or nil when there was nothing to record or the copy failed.
    @discardableResult
    func recordScreenshotSourcePath(_ sourcePath: String?, stepNumber: Int) -> String? {
        guard let sourcePath, !sourcePath.isEmpty else { return nil }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            NSLog("[MonkeyTraceRecorder] Screenshot source missing: \(sourcePath)")
            return nil
        }

        MonkeyTraceRecorder.createDirectoryIfMissing(screenshotsDirectory)

        let fileName = "\(MonkeyTraceRecorder.zeroPadded(stepNumber)).png"
        let destinationURL = screenshotsDirectory.appendingPathComponent(fileName, isDirectory: false)
        let relativePath = "screenshots/\(fileName)"

        // Clear any prior file so the copy / write never fails on an existing item.
        try? fileManager.removeItem(at: destinationURL)

        let sourceURL = URL(fileURLWithPath: sourcePath)

        // Cheapest path: already a PNG → straight copy, no decode/encode cost.
        if sourceURL.pathExtension.lowercased() == "png" {
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return relativePath
            } catch {
                NSLog("[MonkeyTraceRecorder] Failed to copy screenshot \(relativePath): \(error.localizedDescription)")
                // Fall through to a re-encode attempt below.
            }
        }

        // Otherwise decode and re-encode to PNG so trace screenshots are uniform.
        if let sourceData = try? Data(contentsOf: sourceURL),
           let bitmap = NSBitmapImageRep(data: sourceData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            do {
                try pngData.write(to: destinationURL, options: .atomic)
                return relativePath
            } catch {
                NSLog("[MonkeyTraceRecorder] Failed to write re-encoded screenshot \(relativePath): \(error.localizedDescription)")
            }
        } else {
            // Last resort: copy raw bytes under the .png name rather than lose the artifact.
            do {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return relativePath
            } catch {
                NSLog("[MonkeyTraceRecorder] Failed to copy screenshot \(relativePath): \(error.localizedDescription)")
            }
        }

        return nil
    }

    /// Appends one `MonkeyStepRecord` to `steps.jsonl` as a single JSON line.
    ///
    /// The observation and screenshot relative paths (typically the return values of
    /// `recordObservation` / `recordScreenshotSourcePath`) are stored alongside the
    /// record so a replayer can find the artifacts for each step.
    func recordStep(_ record: MonkeyStepRecord, observationFile: String?, screenshotFile: String?) {
        let line: Data
        do {
            line = try encodeStepLine(record, observationFile: observationFile, screenshotFile: screenshotFile)
        } catch {
            NSLog("[MonkeyTraceRecorder] Failed to encode step \(record.stepNumber): \(error.localizedDescription)")
            return
        }

        appendLine(line, to: stepsJSONLURL)
    }

    /// Writes the agent's closing summary to `final_summary.md`. Call once when the run ends.
    func finalize(summary: String) {
        writeTextFile(named: "final_summary.md", contents: summary)
    }

    // MARK: - Step Encoding

    /// On-disk shape of a single `steps.jsonl` line: the step record plus the relative
    /// paths to its observation and screenshot artifacts.
    private struct PersistedStep: Encodable {
        let stepNumber: Int
        let action: MonkeyAction
        let result: String
        let verification: String?
        let observationFile: String?
        let screenshotFile: String?
    }

    private func encodeStepLine(_ record: MonkeyStepRecord, observationFile: String?, screenshotFile: String?) throws -> Data {
        let persisted = PersistedStep(
            stepNumber: record.stepNumber,
            action: record.action,
            result: record.result,
            verification: record.verification,
            observationFile: observationFile,
            screenshotFile: screenshotFile
        )
        return try stepEncoder.encode(persisted)
    }

    // MARK: - File Writing Helpers

    /// Writes a UTF-8 text file at the root of the run directory. Best-effort.
    private func writeTextFile(named fileName: String, contents: String) {
        let destinationURL = runDirectory.appendingPathComponent(fileName, isDirectory: false)
        do {
            try contents.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[MonkeyTraceRecorder] Failed to write \(fileName): \(error.localizedDescription)")
        }
    }

    /// Appends a single line (the given data plus a trailing newline) to a file,
    /// creating the file if it does not yet exist. Best-effort.
    private func appendLine(_ lineData: Data, to fileURL: URL) {
        var payload = lineData
        payload.append(0x0A) // '\n'

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                NSLog("[MonkeyTraceRecorder] Failed to append to \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        } else {
            do {
                try payload.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("[MonkeyTraceRecorder] Failed to create \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Static Helpers

    /// Resolves the base `runs/` directory and ensures it exists.
    ///
    /// Resolution order:
    ///  1. An explicit `override` URL (test injection) — used verbatim as the base.
    ///  2. The `MONKEYBOT_RUNS_DIR` environment variable (treated as the `runs/`
    ///     base directory directly), keeping the base configurable per the contract.
    ///  3. Default: `~/Documents/Monkeybot/runs`.
    private static func resolveRunsBaseDirectory(override: URL? = nil) -> URL {
        let fileManager = FileManager.default

        let baseDirectory: URL
        if let override {
            baseDirectory = override
        } else if let override = ProcessInfo.processInfo.environment["MONKEYBOT_RUNS_DIR"], !override.isEmpty {
            baseDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let documentsDirectory: URL
            if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                documentsDirectory = documents
            } else {
                documentsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Documents", isDirectory: true)
            }
            baseDirectory = documentsDirectory
                .appendingPathComponent("Monkeybot", isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
        }

        createDirectoryIfMissing(baseDirectory)
        return baseDirectory
    }

    /// Creates a directory (and intermediate directories) if it does not already exist.
    private static func createDirectoryIfMissing(_ directory: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[MonkeyTraceRecorder] Failed to create directory \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Builds a filesystem-safe ISO8601 timestamp component for the run directory name,
    /// e.g. `2026-06-13T19-04-22Z`. Colons are illegal in some contexts and ugly in paths,
    /// so they are replaced with hyphens.
    private static func makeTimestampComponent() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let raw = formatter.string(from: Date())
        return raw.replacingOccurrences(of: ":", with: "-")
    }

    /// Sanitizes a slug to a short, lowercase, hyphen-delimited, filesystem-safe token.
    /// Keeps only alphanumerics; everything else collapses to a single hyphen. Caps length.
    private static func sanitizeSlug(_ slug: String) -> String {
        let lowered = slug.lowercased()
        var result = ""
        var lastWasHyphen = false

        for character in lowered {
            if character.isLetter || character.isNumber {
                result.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(48))
    }

    /// Zero-pads a step number to two digits for stable, sortable artifact file names
    /// (e.g. step 3 → "03"). Numbers ≥ 100 keep their natural width.
    private static func zeroPadded(_ stepNumber: Int) -> String {
        String(format: "%02d", stepNumber)
    }
}
