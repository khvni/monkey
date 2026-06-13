//
//  MonkeyAgentLoopHelpersTests.swift
//  leanring-buddyTests
//
//  Unit tests for the pure, deterministic static helpers on MonkeyAgentLoop:
//  capObservation, verificationDelta, makeTraceSlug, statusLine, actionSummary.
//
//  These helpers are MainActor-isolated (their enclosing class is @MainActor),
//  so every test that touches them is annotated @MainActor. No Process exec,
//  no network, no live cua-driver — every fixture is built directly in memory.
//

import Testing
@testable import leanring_buddy

@MainActor
struct MonkeyAgentLoopHelpersTests {

    // MARK: - capObservation

    @Test func capObservationReturnsInputUnchangedWhenUnderLimit() {
        let markdown = "short observation"
        let result = MonkeyAgentLoop.capObservation(markdown, limit: 100)
        #expect(result == markdown)
    }

    @Test func capObservationReturnsInputUnchangedAtExactlyLimit() {
        // count == limit is NOT over the limit (guard is `> limit`), so untouched.
        let markdown = String(repeating: "x", count: 50)
        let result = MonkeyAgentLoop.capObservation(markdown, limit: 50)
        #expect(result == markdown)
    }

    @Test func capObservationTruncatesAndAppendsNoteWhenOverLimit() {
        let limit = 200
        let markdown = String(repeating: "a", count: limit + 500)
        let result = MonkeyAgentLoop.capObservation(markdown, limit: limit)

        // The head is exactly `limit` characters; the rest is the truncation note.
        #expect(result != markdown)
        #expect(result.count > limit) // head + note
        #expect(result.hasPrefix(String(repeating: "a", count: limit)))
        #expect(result.contains("observation truncated to \(limit) characters"))
        #expect(result.contains("scroll to reveal more elements"))

        // Length bound: head (limit) + the fixed note, and never includes the
        // characters beyond `limit` from the source body itself.
        let note = "\n\n…[observation truncated to \(limit) characters — scroll to reveal more elements, or narrow the task]"
        #expect(result.count == limit + note.count)
    }

    @Test func capObservationDefaultLimitLeavesModerateObservationUntouched() {
        // Default limit is 12_000; a 1k-char body is well under it.
        let markdown = String(repeating: "z", count: 1_000)
        let result = MonkeyAgentLoop.capObservation(markdown)
        #expect(result == markdown)
    }

    // MARK: - verificationDelta

    @Test func verificationDeltaReportsUIChangedWhenTreeDiffersAndElementsAppeared() {
        let before = CuaObservation(treeMarkdown: "tree A", elementCount: 3, screenshotFilePath: nil)
        let after = CuaObservation(treeMarkdown: "tree B", elementCount: 5, screenshotFilePath: nil)

        let result = MonkeyAgentLoop.verificationDelta(before: before, after: after)
        #expect(result == "UI changed: 2 element(s) appeared")
    }

    @Test func verificationDeltaReportsUIChangedWhenElementsDisappeared() {
        let before = CuaObservation(treeMarkdown: "tree A", elementCount: 7, screenshotFilePath: nil)
        let after = CuaObservation(treeMarkdown: "tree B", elementCount: 4, screenshotFilePath: nil)

        let result = MonkeyAgentLoop.verificationDelta(before: before, after: after)
        #expect(result == "UI changed: 3 element(s) disappeared")
    }

    @Test func verificationDeltaReportsUIUnchangedWhenTreeIdenticalAndCountSame() {
        let before = CuaObservation(treeMarkdown: "same tree", elementCount: 6, screenshotFilePath: nil)
        let after = CuaObservation(treeMarkdown: "same tree", elementCount: 6, screenshotFilePath: nil)

        let result = MonkeyAgentLoop.verificationDelta(before: before, after: after)
        #expect(result == "UI unchanged: element count unchanged (6)")
    }

    @Test func verificationDeltaReportsUIChangedWithUnchangedCountWhenOnlyTreeDiffers() {
        // Tree markdown differs but element count is identical — "UI changed"
        // prefix with the "element count unchanged (N)" note.
        let before = CuaObservation(treeMarkdown: "tree v1", elementCount: 9, screenshotFilePath: nil)
        let after = CuaObservation(treeMarkdown: "tree v2", elementCount: 9, screenshotFilePath: nil)

        let result = MonkeyAgentLoop.verificationDelta(before: before, after: after)
        #expect(result == "UI changed: element count unchanged (9)")
    }

    @Test func verificationDeltaReportsUIUnchangedEvenWhenCountChangesIfTreeIdentical() {
        // Tree markdown identical drives the "UI unchanged" prefix regardless of
        // the count delta note (an unlikely-but-defined edge of the logic).
        let before = CuaObservation(treeMarkdown: "identical", elementCount: 2, screenshotFilePath: nil)
        let after = CuaObservation(treeMarkdown: "identical", elementCount: 5, screenshotFilePath: nil)

        let result = MonkeyAgentLoop.verificationDelta(before: before, after: after)
        #expect(result == "UI unchanged: 3 element(s) appeared")
    }

    // MARK: - makeTraceSlug

    @Test func makeTraceSlugLowercasesAndHyphenatesWhitespace() {
        let slug = MonkeyAgentLoop.makeTraceSlug(fromTask: "Find Clay Contact")
        #expect(slug == "find-clay-contact")
    }

    @Test func makeTraceSlugReplacesNonAlphanumericsAndCollapsesRepeats() {
        // Multiple punctuation/space runs collapse into a single hyphen each,
        // and leading/trailing separators are omitted (omittingEmptySubsequences).
        let slug = MonkeyAgentLoop.makeTraceSlug(fromTask: "  Hello, World!!  ")
        #expect(slug == "hello-world")
    }

    @Test func makeTraceSlugKeepsAlphanumericsIncludingDigits() {
        let slug = MonkeyAgentLoop.makeTraceSlug(fromTask: "Open tab 3 now")
        #expect(slug == "open-tab-3-now")
    }

    @Test func makeTraceSlugCapsLengthAtFortyCharacters() {
        // A long all-letters task gets prefixed to 40 chars. Use letters so no
        // hyphen lands on the boundary to keep the expectation unambiguous.
        let task = String(repeating: "a", count: 100)
        let slug = MonkeyAgentLoop.makeTraceSlug(fromTask: task)
        #expect(slug.count == 40)
        #expect(slug == String(repeating: "a", count: 40))
    }

    @Test func makeTraceSlugFallsBackToTaskForEmptyInput() {
        #expect(MonkeyAgentLoop.makeTraceSlug(fromTask: "") == "task")
    }

    @Test func makeTraceSlugFallsBackToTaskForPunctuationOnlyInput() {
        // All-separator input collapses to empty, then falls back to "task".
        #expect(MonkeyAgentLoop.makeTraceSlug(fromTask: "!!! ??? ...") == "task")
    }

    // MARK: - statusLine

    @Test func statusLineClickWithElementIndex() {
        let action = MonkeyAction(action: .click, elementIndex: 12)
        #expect(MonkeyAgentLoop.statusLine(for: action) == "clicking [12]")
    }

    @Test func statusLineClickWithCoordinatesWhenNoElementIndex() {
        let action = MonkeyAction(action: .click, x: 42.7, y: 100.2)
        #expect(MonkeyAgentLoop.statusLine(for: action) == "clicking (42, 100)")
    }

    @Test func statusLineTypeText() {
        let action = MonkeyAction(action: .type_text, text: "anything")
        #expect(MonkeyAgentLoop.statusLine(for: action) == "typing text")
    }

    @Test func statusLineScrollUsesDirection() {
        let action = MonkeyAction(action: .scroll, direction: "down")
        #expect(MonkeyAgentLoop.statusLine(for: action) == "scrolling down")
    }

    @Test func statusLineHotkeyJoinsKeysWithPlus() {
        let action = MonkeyAction(action: .hotkey, keys: ["cmd", "c"])
        #expect(MonkeyAgentLoop.statusLine(for: action) == "hotkey cmd+c")
    }

    @Test func statusLineDone() {
        let action = MonkeyAction(action: .done, summary: "finished")
        #expect(MonkeyAgentLoop.statusLine(for: action) == "done")
    }

    @Test func statusLineAskUser() {
        let action = MonkeyAction(action: .ask_user, question: "which one?")
        #expect(MonkeyAgentLoop.statusLine(for: action) == "asking user")
    }

    // MARK: - actionSummary

    @Test func actionSummaryClickWithElementIndex() {
        let action = MonkeyAction(action: .click, elementIndex: 7)
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "click element [7]")
    }

    @Test func actionSummaryClickWithCoordinatesWhenNoElementIndex() {
        let action = MonkeyAction(action: .click, x: 10.9, y: 20.1)
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "click at (10, 20)")
    }

    @Test func actionSummaryTypeTextTruncatesLongTextAtFortyChars() {
        // 50 'b' chars > 40 limit → prefix(40) + ellipsis, wrapped in quotes.
        let longText = String(repeating: "b", count: 50)
        let action = MonkeyAction(action: .type_text, text: longText)
        let expected = "type \"\(String(repeating: "b", count: 40))…\""
        #expect(MonkeyAgentLoop.actionSummary(for: action) == expected)
    }

    @Test func actionSummaryTypeTextShortTextIsNotTruncated() {
        let action = MonkeyAction(action: .type_text, text: "hello")
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "type \"hello\"")
    }

    @Test func actionSummaryScrollIncludesDirectionByAndAmount() {
        let action = MonkeyAction(action: .scroll, direction: "up", by: "page", amount: 3)
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "scroll up by page x3")
    }

    @Test func actionSummaryHotkeyJoinsKeysWithPlus() {
        let action = MonkeyAction(action: .hotkey, keys: ["cmd", "shift", "t"])
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "hotkey cmd+shift+t")
    }

    @Test func actionSummaryDone() {
        let action = MonkeyAction(action: .done, summary: "all set")
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "done")
    }

    @Test func actionSummaryAskUser() {
        let action = MonkeyAction(action: .ask_user, question: "need input")
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "ask user")
    }

    @Test func actionSummaryAppendsTruncatedReasonWhenPresent() {
        // A non-empty reason is appended as " — <reason>" (reason truncated to 80).
        let action = MonkeyAction(action: .click, reason: "the primary submit button", elementIndex: 4)
        #expect(MonkeyAgentLoop.actionSummary(for: action) == "click element [4] — the primary submit button")
    }
}
