import Foundation

/// The set of structured actions the agent runtime is allowed to emit.
/// Raw values are the exact strings the model writes into the `action` JSON field
/// and (for the cua-bound kinds) map onto the snake_case cua-driver tool names.
enum MonkeyActionKind: String, Codable, CaseIterable {
    case observe, click, type_text, set_value, scroll, press_key, hotkey, wait, done, ask_user
}

/// One structured action emitted by the agent runtime. Decoded from strict JSON.
///
/// The model is required to produce exactly one JSON object matching this shape per turn.
/// Every field other than `action` is optional at the decode layer; per-kind required-field
/// rules are enforced separately by `validate()` so that decode failures and semantic
/// validation failures can be surfaced distinctly when re-prompting the model.
struct MonkeyAction: Codable {
    let action: MonkeyActionKind
    // Every payload field defaults to nil so the synthesized memberwise
    // initializer is usable directly (e.g. MonkeyAction(action: .observe)) without
    // forcing callers to decode a literal or supply every field.
    var reason: String? = nil            // model rationale, logged to trace (optional)
    // targeting
    var elementIndex: Int? = nil         // JSON key: element_index
    var x: Double? = nil
    var y: Double? = nil
    var cssSelector: String? = nil       // JSON key: css_selector (web/DOM click target)
    // payloads
    var text: String? = nil              // type_text
    var value: String? = nil             // set_value
    var key: String? = nil               // press_key (e.g. "Return","Escape","Tab")
    var keys: [String]? = nil            // hotkey combo (e.g. ["cmd","c"])
    var direction: String? = nil         // scroll: up|down|left|right
    var by: String? = nil                // scroll: line|page
    var amount: Int? = nil               // scroll repetitions
    var seconds: Double? = nil           // wait
    var summary: String? = nil           // done: final summary text
    var question: String? = nil          // ask_user: question to surface to user

    enum CodingKeys: String, CodingKey {
        case action, reason, x, y, text, value, key, keys, direction, by, amount, seconds, summary, question
        case elementIndex = "element_index"
        case cssSelector = "css_selector"
    }
}

/// Semantic validation failures for an otherwise-decodable `MonkeyAction`.
/// These are distinct from JSON decode errors so the runtime can re-prompt with a
/// precise, human-readable explanation of which field the model omitted.
enum MonkeyActionValidationError: Error, CustomStringConvertible {
    /// A field required by the action's kind was missing (or empty where non-empty is required).
    case missingField(action: MonkeyActionKind, field: String)
    /// A `click` action provided neither `element_index` nor a complete `(x, y)` coordinate pair.
    case noTarget(action: MonkeyActionKind)

    var description: String {
        switch self {
        case let .missingField(action, field):
            return "Action '\(action.rawValue)' is missing required field '\(field)'."
        case let .noTarget(action):
            return "Action '\(action.rawValue)' needs a target: provide 'element_index', both 'x' and 'y', or 'css_selector'."
        }
    }
}

extension MonkeyAction {
    /// Wait duration to actually sleep for, honoring the lenient default of 1 second
    /// when the model omits `seconds`. Negative values are clamped to 0.
    var effectiveWaitSeconds: Double {
        max(0, seconds ?? 1)
    }

    /// Parse strict JSON (single object) out of raw model text.
    ///
    /// The model is instructed to emit a bare JSON object, but it sometimes wraps the
    /// payload in Markdown code fences (```json … ```) or surrounds it with prose. This
    /// strips any fences and extracts the first balanced top-level `{ … }` object, then
    /// decodes it. On failure it throws the underlying decode error so the caller can
    /// re-prompt with the original text.
    static func parse(fromModelText raw: String) throws -> MonkeyAction {
        let candidate = extractFirstJSONObject(from: stripCodeFences(from: raw))
        let jsonText = candidate ?? raw
        guard let data = jsonText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Model text was not valid UTF-8 and could not be decoded as JSON."
                )
            )
        }
        return try JSONDecoder().decode(MonkeyAction.self, from: data)
    }

    /// Per-kind required-field validation. Throws `MonkeyActionValidationError` on a malformed action.
    func validate() throws {
        switch action {
        case .observe:
            // No fields required.
            break

        case .click:
            // Requires element_index OR (x AND y) OR css_selector.
            // css_selector is the additive web/DOM target; it is only acted on
            // when browser grounding is active (the loop falls back to AX
            // element_index otherwise), but it satisfies validation here so the
            // model may emit it without the action being rejected.
            let hasElementTarget = elementIndex != nil
            let hasCoordinateTarget = (x != nil && y != nil)
            let hasCssSelectorTarget = (cssSelector?.isEmpty == false)
            guard hasElementTarget || hasCoordinateTarget || hasCssSelectorTarget else {
                throw MonkeyActionValidationError.noTarget(action: action)
            }

        case .type_text:
            // Requires text (element_index optional → focused element).
            guard text != nil else {
                throw MonkeyActionValidationError.missingField(action: action, field: "text")
            }

        case .set_value:
            // Requires element_index AND value.
            guard elementIndex != nil else {
                throw MonkeyActionValidationError.missingField(action: action, field: "element_index")
            }
            guard value != nil else {
                throw MonkeyActionValidationError.missingField(action: action, field: "value")
            }

        case .scroll:
            // Requires direction.
            guard let direction, !direction.isEmpty else {
                throw MonkeyActionValidationError.missingField(action: action, field: "direction")
            }

        case .press_key:
            // Requires key.
            guard let key, !key.isEmpty else {
                throw MonkeyActionValidationError.missingField(action: action, field: "key")
            }

        case .hotkey:
            // Requires non-empty keys.
            guard let keys, !keys.isEmpty else {
                throw MonkeyActionValidationError.missingField(action: action, field: "keys")
            }

        case .wait:
            // Lenient: `seconds` may be omitted; callers use `effectiveWaitSeconds`,
            // which defaults to 1 second when absent. Always valid.
            break

        case .done:
            // Requires summary.
            guard let summary, !summary.isEmpty else {
                throw MonkeyActionValidationError.missingField(action: action, field: "summary")
            }

        case .ask_user:
            // Requires question.
            guard let question, !question.isEmpty else {
                throw MonkeyActionValidationError.missingField(action: action, field: "question")
            }
        }
    }

    // MARK: - Raw-text extraction helpers

    /// Removes Markdown code fences (```json … ``` or ``` … ```) from model output,
    /// returning the inner content when a fenced block is present, otherwise the input unchanged.
    private static func stripCodeFences(from raw: String) -> String {
        guard let openingFenceRange = raw.range(of: "```") else {
            return raw
        }
        // Drop everything up to and including the opening fence.
        var afterOpeningFence = raw[openingFenceRange.upperBound...]
        // The opening fence may carry an info string (e.g. "json") up to the first newline.
        if let firstNewlineIndex = afterOpeningFence.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let infoString = afterOpeningFence[afterOpeningFence.startIndex..<firstNewlineIndex]
                .trimmingCharacters(in: .whitespaces)
            // Only treat the leading token as an info string (e.g. "json"); never strip JSON content.
            if !infoString.contains("{") {
                afterOpeningFence = afterOpeningFence[afterOpeningFence.index(after: firstNewlineIndex)...]
            }
        }
        // Drop the closing fence and anything after it, if present.
        if let closingFenceRange = afterOpeningFence.range(of: "```") {
            return String(afterOpeningFence[afterOpeningFence.startIndex..<closingFenceRange.lowerBound])
        }
        return String(afterOpeningFence)
    }

    /// Extracts the first balanced top-level JSON object (`{ … }`) from the text,
    /// honoring string literals and escape sequences so braces inside strings don't
    /// throw off the brace-depth counter. Returns nil when no complete object is found.
    private static func extractFirstJSONObject(from text: String) -> String? {
        guard let objectStartIndex = text.firstIndex(of: "{") else {
            return nil
        }
        var braceDepth = 0
        var isInsideStringLiteral = false
        var isEscapingNextCharacter = false
        var currentIndex = objectStartIndex

        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            if isEscapingNextCharacter {
                isEscapingNextCharacter = false
            } else if character == "\\" {
                isEscapingNextCharacter = true
            } else if character == "\"" {
                isInsideStringLiteral.toggle()
            } else if !isInsideStringLiteral {
                if character == "{" {
                    braceDepth += 1
                } else if character == "}" {
                    braceDepth -= 1
                    if braceDepth == 0 {
                        let objectEndIndex = text.index(after: currentIndex)
                        return String(text[objectStartIndex..<objectEndIndex])
                    }
                }
            }

            currentIndex = text.index(after: currentIndex)
        }
        // Unbalanced braces — no complete object available.
        return nil
    }
}
