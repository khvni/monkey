//
//  MonkeyActionTests.swift
//  leanring-buddyTests
//
//  Unit tests for MonkeyAction.parse(fromModelText:) and MonkeyAction.validate().
//  Pure/deterministic logic only — no Process, network, cua-driver, or screenshots.
//

import Testing
@testable import leanring_buddy

struct MonkeyActionTests {

    // MARK: - parse(fromModelText:)

    @Test func parseBareJSONObject() throws {
        let raw = #"{"action": "observe", "reason": "look around"}"#
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .observe)
        #expect(action.reason == "look around")
    }

    @Test func parseJSONWrappedInJSONFences() throws {
        let raw = """
        ```json
        {"action": "click", "element_index": 7}
        ```
        """
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .click)
        #expect(action.elementIndex == 7)
    }

    @Test func parseJSONWrappedInBareFences() throws {
        let raw = """
        ```
        {"action": "wait", "seconds": 2.5}
        ```
        """
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .wait)
        #expect(action.seconds == 2.5)
    }

    @Test func parseJSONSurroundedByProse() throws {
        let raw = """
        Sure! I'll click the button now. Here is the action:
        {"action": "click", "x": 12.0, "y": 34.0}
        Let me know if that worked.
        """
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .click)
        #expect(action.x == 12.0)
        #expect(action.y == 34.0)
    }

    @Test func parseNestedBracesExtractsCompleteObject() throws {
        // A top-level object containing a nested object value. Balanced-brace
        // extraction must consume the inner braces and stop at the matching close.
        let raw = #"prefix {"action": "done", "summary": "wrapped {nested} value"} suffix"#
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .done)
        #expect(action.summary == "wrapped {nested} value")
    }

    @Test func parseBracesInsideStringValuesDoNotConfuseDepthCounter() throws {
        // Braces appear only inside a string literal; the brace-depth counter must
        // ignore them and close at the real top-level closing brace.
        let raw = #"{"action": "type_text", "text": "if (x) { return {a: 1}; }"}"#
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .type_text)
        #expect(action.text == "if (x) { return {a: 1}; }")
    }

    @Test func parseEscapedQuotesInsideStringAreHonored() throws {
        // An escaped quote inside a string must not prematurely toggle string state,
        // so a brace following the escaped quote stays "inside" the string.
        let raw = #"{"action": "done", "summary": "she said \"hi\" } and left"}"#
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .done)
        #expect(action.summary == #"she said "hi" } and left"#)
    }

    @Test func parseLeadingAndTrailingWhitespace() throws {
        let raw = "   \n\t  {\"action\": \"observe\"}  \n\n  "
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .observe)
    }

    @Test func parseInvalidNonJSONThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try MonkeyAction.parse(fromModelText: "this is just prose, no json here")
        }
    }

    @Test func parseEmptyStringThrows() throws {
        #expect(throws: (any Error).self) {
            _ = try MonkeyAction.parse(fromModelText: "")
        }
    }

    // MARK: - validate(): observe

    @Test func validateObserveAlwaysValid() throws {
        try MonkeyAction(action: .observe).validate()
    }

    // MARK: - validate(): click

    @Test func validateClickWithElementIndex() throws {
        var action = MonkeyAction(action: .click)
        action.elementIndex = 3
        try action.validate()
    }

    @Test func validateClickWithCoordinates() throws {
        var action = MonkeyAction(action: .click)
        action.x = 10
        action.y = 20
        try action.validate()
    }

    @Test func validateClickWithCSSSelector() throws {
        // v0.3 addition: css_selector satisfies the click target requirement.
        var action = MonkeyAction(action: .click)
        action.cssSelector = "button.submit"
        try action.validate()
    }

    @Test func validateClickWithEmptyCSSSelectorIsNotATarget() throws {
        // An empty css_selector does not count as a target on its own.
        var action = MonkeyAction(action: .click)
        action.cssSelector = ""
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateClickWithOnlyXThrows() throws {
        // A single coordinate is not a complete (x, y) pair.
        var action = MonkeyAction(action: .click)
        action.x = 10
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateClickWithNoTargetThrowsNoTarget() throws {
        let action = MonkeyAction(action: .click)
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .noTarget(kind) = error else {
            Issue.record("Expected .noTarget, got \(error)")
            return
        }
        #expect(kind == .click)
    }

    // MARK: - validate(): type_text

    @Test func validateTypeTextWithText() throws {
        var action = MonkeyAction(action: .type_text)
        action.text = "hello"
        try action.validate()
    }

    @Test func validateTypeTextWithEmptyTextIsValid() throws {
        // type_text only requires text to be non-nil, not non-empty.
        var action = MonkeyAction(action: .type_text)
        action.text = ""
        try action.validate()
    }

    @Test func validateTypeTextMissingTextThrows() throws {
        let action = MonkeyAction(action: .type_text)
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .type_text)
        #expect(field == "text")
    }

    // MARK: - validate(): set_value

    @Test func validateSetValueWithElementIndexAndValue() throws {
        var action = MonkeyAction(action: .set_value)
        action.elementIndex = 5
        action.value = "typed value"
        try action.validate()
    }

    @Test func validateSetValueMissingElementIndexThrows() throws {
        var action = MonkeyAction(action: .set_value)
        action.value = "typed value"
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .set_value)
        #expect(field == "element_index")
    }

    @Test func validateSetValueMissingValueThrows() throws {
        var action = MonkeyAction(action: .set_value)
        action.elementIndex = 5
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .set_value)
        #expect(field == "value")
    }

    // MARK: - validate(): scroll

    @Test func validateScrollWithDirection() throws {
        var action = MonkeyAction(action: .scroll)
        action.direction = "down"
        try action.validate()
    }

    @Test func validateScrollMissingDirectionThrows() throws {
        let action = MonkeyAction(action: .scroll)
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateScrollEmptyDirectionThrows() throws {
        var action = MonkeyAction(action: .scroll)
        action.direction = ""
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .scroll)
        #expect(field == "direction")
    }

    // MARK: - validate(): press_key

    @Test func validatePressKeyWithKey() throws {
        var action = MonkeyAction(action: .press_key)
        action.key = "Return"
        try action.validate()
    }

    @Test func validatePressKeyMissingKeyThrows() throws {
        let action = MonkeyAction(action: .press_key)
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validatePressKeyEmptyKeyThrows() throws {
        var action = MonkeyAction(action: .press_key)
        action.key = ""
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .press_key)
        #expect(field == "key")
    }

    // MARK: - validate(): hotkey

    @Test func validateHotkeyWithKeys() throws {
        var action = MonkeyAction(action: .hotkey)
        action.keys = ["cmd", "c"]
        try action.validate()
    }

    @Test func validateHotkeyMissingKeysThrows() throws {
        let action = MonkeyAction(action: .hotkey)
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateHotkeyEmptyKeysThrows() throws {
        var action = MonkeyAction(action: .hotkey)
        action.keys = []
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .hotkey)
        #expect(field == "keys")
    }

    // MARK: - validate(): wait (always valid, lenient)

    @Test func validateWaitWithSeconds() throws {
        var action = MonkeyAction(action: .wait)
        action.seconds = 3
        try action.validate()
    }

    @Test func validateWaitWithoutSecondsIsValid() throws {
        // Lenient: seconds may be omitted.
        try MonkeyAction(action: .wait).validate()
    }

    @Test func waitWithoutSecondsDefaultsToOneSecond() throws {
        #expect(MonkeyAction(action: .wait).effectiveWaitSeconds == 1)
    }

    @Test func waitNegativeSecondsClampedToZero() throws {
        var action = MonkeyAction(action: .wait)
        action.seconds = -5
        #expect(action.effectiveWaitSeconds == 0)
    }

    // MARK: - validate(): done

    @Test func validateDoneWithSummary() throws {
        var action = MonkeyAction(action: .done)
        action.summary = "task complete"
        try action.validate()
    }

    @Test func validateDoneMissingSummaryThrows() throws {
        let action = MonkeyAction(action: .done)
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateDoneEmptySummaryThrows() throws {
        var action = MonkeyAction(action: .done)
        action.summary = ""
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .done)
        #expect(field == "summary")
    }

    // MARK: - validate(): ask_user

    @Test func validateAskUserWithQuestion() throws {
        var action = MonkeyAction(action: .ask_user)
        action.question = "Which file should I open?"
        try action.validate()
    }

    @Test func validateAskUserMissingQuestionThrows() throws {
        let action = MonkeyAction(action: .ask_user)
        #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
    }

    @Test func validateAskUserEmptyQuestionThrows() throws {
        var action = MonkeyAction(action: .ask_user)
        action.question = ""
        let thrown = #expect(throws: MonkeyActionValidationError.self) {
            try action.validate()
        }
        let error = try #require(thrown)
        guard case let .missingField(kind, field) = error else {
            Issue.record("Expected .missingField, got \(error)")
            return
        }
        #expect(kind == .ask_user)
        #expect(field == "question")
    }

    // MARK: - parse + validate end-to-end (css_selector click path, v0.3)

    @Test func parseThenValidateCSSSelectorClick() throws {
        let raw = #"{"action": "click", "css_selector": "a#login", "reason": "open login"}"#
        let action = try MonkeyAction.parse(fromModelText: raw)
        #expect(action.action == .click)
        #expect(action.cssSelector == "a#login")
        try action.validate()
    }
}
