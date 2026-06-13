//
//  MonkeyTraceRecorderTests.swift
//  leanring-buddyTests
//
//  Trace I/O tests for MonkeyTraceRecorder. Every test injects a fresh temp
//  directory via the `baseDirectoryOverride` seam so nothing ever touches the
//  real ~/Documents/Monkeybot/runs tree, and tears that temp dir down after.
//
//  Swift Testing (import Testing; @Test; #expect / #require) — NOT XCTest.
//

import Testing
import Foundation
@testable import leanring_buddy

@MainActor
struct MonkeyTraceRecorderTests {

    // MARK: - Temp dir helpers

    /// Makes a unique temp directory to stand in for the `runs/` base dir.
    /// Returned URL does not yet exist; the recorder creates it on init.
    private static func makeTempBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MonkeyTraceRecorderTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Best-effort recursive cleanup of a temp dir created for one test.
    private static func removeTempDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Fixtures

    /// Builds a MonkeyStepRecord directly via its memberwise init, wrapping a
    /// MonkeyAction fixture so the encoded JSON line has real action content.
    private static func makeStepRecord(stepNumber: Int) -> MonkeyStepRecord {
        let action = MonkeyAction(
            action: .click,
            reason: "tap the primary button",
            elementIndex: stepNumber
        )
        return MonkeyStepRecord(
            stepNumber: stepNumber,
            action: action,
            result: "ok-\(stepNumber)",
            verification: "delta-\(stepNumber)"
        )
    }

    /// Minimal on-disk shape mirroring MonkeyTraceRecorder.PersistedStep (which is
    /// private). Decoding each steps.jsonl line into this proves the line is valid,
    /// single-object JSON carrying the expected fields.
    private struct DecodedStepLine: Decodable {
        let stepNumber: Int
        let action: MonkeyAction
        let result: String
        let verification: String?
        let observationFile: String?
        let screenshotFile: String?
    }

    // MARK: - init

    @Test func initCreatesRunDirectoryAndWritesTaskAndTranscript() throws {
        let baseDirectory = Self.makeTempBaseDirectory()
        defer { Self.removeTempDirectory(baseDirectory) }

        let task = "Book a table for two at 7pm"
        let transcript = "uh hey can you book a table for two at like seven tonight"

        let recorder = MonkeyTraceRecorder(
            task: task,
            transcript: transcript,
            slug: "book-a-table",
            baseDirectoryOverride: baseDirectory
        )

        let runDirectory = recorder.runDirectoryURL
        let fileManager = FileManager.default

        // The run directory must exist and live directly under the injected base dir.
        var isDirectory: ObjCBool = false
        #expect(fileManager.fileExists(atPath: runDirectory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(runDirectory.deletingLastPathComponent().path == baseDirectory.path)

        // The sanitized slug should appear in the run directory name.
        #expect(runDirectory.lastPathComponent.contains("book-a-table"))

        // task.txt and transcript.txt must be written with exactly the given content.
        let taskURL = runDirectory.appendingPathComponent("task.txt")
        let transcriptURL = runDirectory.appendingPathComponent("transcript.txt")

        #expect(fileManager.fileExists(atPath: taskURL.path))
        #expect(fileManager.fileExists(atPath: transcriptURL.path))

        let writtenTask = try String(contentsOf: taskURL, encoding: .utf8)
        let writtenTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)

        #expect(writtenTask == task)
        #expect(writtenTranscript == transcript)
    }

    // MARK: - recordStep

    @Test func recordStepAppendsOneValidJSONLinePerCall() throws {
        let baseDirectory = Self.makeTempBaseDirectory()
        defer { Self.removeTempDirectory(baseDirectory) }

        let recorder = MonkeyTraceRecorder(
            task: "task",
            transcript: "transcript",
            slug: "steps-run",
            baseDirectoryOverride: baseDirectory
        )

        let stepCount = 3
        for stepNumber in 1...stepCount {
            let record = Self.makeStepRecord(stepNumber: stepNumber)
            recorder.recordStep(
                record,
                observationFile: "observations/\(String(format: "%02d", stepNumber)).md",
                screenshotFile: nil
            )
        }

        let stepsURL = recorder.runDirectoryURL.appendingPathComponent("steps.jsonl")
        #expect(FileManager.default.fileExists(atPath: stepsURL.path))

        let rawContents = try String(contentsOf: stepsURL, encoding: .utf8)

        // One JSON line per recordStep call (trailing newline => last element is empty).
        let lines = rawContents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }

        #expect(lines.count == stepCount)

        // Decode each line back to confirm it is valid, single-object JSON with the
        // expected stepNumber / action / result content.
        let decoder = JSONDecoder()
        for (index, line) in lines.enumerated() {
            let expectedStepNumber = index + 1
            let lineData = try #require(line.data(using: .utf8))
            let decoded = try decoder.decode(DecodedStepLine.self, from: lineData)

            #expect(decoded.stepNumber == expectedStepNumber)
            #expect(decoded.result == "ok-\(expectedStepNumber)")
            #expect(decoded.verification == "delta-\(expectedStepNumber)")
            #expect(decoded.action.action == .click)
            #expect(decoded.action.elementIndex == expectedStepNumber)
            #expect(decoded.observationFile == "observations/\(String(format: "%02d", expectedStepNumber)).md")
            #expect(decoded.screenshotFile == nil)
        }
    }

    // MARK: - recordObservation

    @Test func recordObservationWritesFileAndReturnsRelativePath() throws {
        let baseDirectory = Self.makeTempBaseDirectory()
        defer { Self.removeTempDirectory(baseDirectory) }

        let recorder = MonkeyTraceRecorder(
            task: "task",
            transcript: "transcript",
            slug: "observe-run",
            baseDirectoryOverride: baseDirectory
        )

        let markdown = "# Window State\n- button[1]: Submit\n- field[2]: Name"
        let relativePath = recorder.recordObservation(stepNumber: 7, markdown: markdown)

        // The returned path is relative to the run dir, zero-padded to two digits.
        #expect(relativePath == "observations/07.md")

        let observationURL = recorder.runDirectoryURL.appendingPathComponent(relativePath)
        #expect(FileManager.default.fileExists(atPath: observationURL.path))

        let writtenMarkdown = try String(contentsOf: observationURL, encoding: .utf8)
        #expect(writtenMarkdown == markdown)
    }

    // MARK: - finalize

    @Test func finalizeWritesFinalSummary() throws {
        let baseDirectory = Self.makeTempBaseDirectory()
        defer { Self.removeTempDirectory(baseDirectory) }

        let recorder = MonkeyTraceRecorder(
            task: "task",
            transcript: "transcript",
            slug: "finalize-run",
            baseDirectoryOverride: baseDirectory
        )

        let summary = "## Done\nBooked the table for two at 7:00pm."
        recorder.finalize(summary: summary)

        let summaryURL = recorder.runDirectoryURL.appendingPathComponent("final_summary.md")
        #expect(FileManager.default.fileExists(atPath: summaryURL.path))

        let writtenSummary = try String(contentsOf: summaryURL, encoding: .utf8)
        #expect(writtenSummary == summary)
    }
}
