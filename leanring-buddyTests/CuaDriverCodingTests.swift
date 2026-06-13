//
//  CuaDriverCodingTests.swift
//  leanring-buddyTests
//
//  Pure coding-seam tests for CuaDriverClient — NO Process exec, NO network,
//  NO live cua-driver, NO real screenshots. Exercises only deterministic,
//  side-effect-free logic:
//
//   1. CuaDriverClient.compactJSONString(from:) — compact, sorted-key,
//      slash-unescaped JSON serialization of an argument dictionary.
//   2. CuaDriverClient.decodeWindows(from:) — the pure decode entry point for a
//      `list_windows` payload, mapping the driver's snake_case wire keys onto
//      CuaWindow's Swift properties.
//   3. CuaObservation field/key mapping for a `get_window_state` payload. The
//      driver's wire struct (GetWindowStateResponse) is private, so this test
//      decodes the fixture with the SAME snake_case CodingKeys the production
//      code declares and builds a CuaObservation via its synthesized memberwise
//      init — asserting snake_case -> Swift-property mapping end to end.
//
//  All exercised symbols are @MainActor-isolated (their enclosing class is
//  @MainActor), so every test runs on the main actor.
//

import Testing
import Foundation
@testable import leanring_buddy

// MARK: - compactJSONString

@MainActor
struct CuaDriverCompactJSONStringTests {

    @Test func emptyDictionaryProducesEmptyObjectLiteral() throws {
        let json = try CuaDriverClient.compactJSONString(from: [:])
        #expect(json == "{}")
    }

    @Test func sortsKeysAndUsesSnakeCaseKeysExactly() throws {
        // Insertion order is deliberately NOT sorted to prove .sortedKeys works.
        let json = try CuaDriverClient.compactJSONString(from: [
            "window_id": 3,
            "element_index": 1,
            "pid": 2
        ])
        // Full-string assertion: sorted keys -> element_index, pid, window_id.
        #expect(json == #"{"element_index":1,"pid":2,"window_id":3}"#)
    }

    @Test func singleKeyDictionaryIsCompact() throws {
        let json = try CuaDriverClient.compactJSONString(from: ["pid": 42])
        #expect(json == #"{"pid":42}"#)
    }

    @Test func producesNoPrettyPrintingWhitespace() throws {
        let json = try CuaDriverClient.compactJSONString(from: [
            "pid": 2,
            "window_id": 3
        ])
        // Compact output: no newlines, no spaces between tokens.
        #expect(!json.contains("\n"))
        #expect(!json.contains(" "))
        #expect(json == #"{"pid":2,"window_id":3}"#)
    }

    @Test func doesNotEscapeForwardSlashes() throws {
        // withoutEscapingSlashes: a path-bearing value stays "/tmp/x.png",
        // never "\/tmp\/x.png".
        let json = try CuaDriverClient.compactJSONString(from: [
            "screenshot_out_file": "/tmp/shot.png"
        ])
        #expect(json == #"{"screenshot_out_file":"/tmp/shot.png"}"#)
        #expect(json.contains("/tmp/shot.png"))
        #expect(!json.contains("\\/"))
    }

    @Test func encodesStringValuesQuotedAndSorted() throws {
        let json = try CuaDriverClient.compactJSONString(from: [
            "text": "hello",
            "key": "return"
        ])
        // Sorted keys: "key" < "text".
        #expect(json == #"{"key":"return","text":"hello"}"#)
    }
}

// MARK: - decodeWindows (list_windows envelope)

@MainActor
struct CuaDriverDecodeWindowsTests {

    /// A realistic `list_windows` envelope: the windows array plus the extra
    /// `current_space_id` field the driver also emits (which the envelope ignores).
    private static let listWindowsFixture = Data(#"""
    {
      "windows": [
        {
          "app_name": "Google Chrome",
          "pid": 501,
          "window_id": 91011,
          "title": "Clay - New Tab",
          "is_on_screen": true,
          "bounds": { "x": 10, "y": 20, "width": 1280, "height": 800 }
        },
        {
          "app_name": "Finder",
          "pid": 600,
          "window_id": 12,
          "title": "Downloads",
          "is_on_screen": false,
          "bounds": { "x": 0, "y": 0, "width": 640, "height": 480 }
        }
      ],
      "current_space_id": 7
    }
    """#.utf8)

    @Test func decodesAllWindowsFromEnvelope() throws {
        let windows = try CuaDriverClient.decodeWindows(from: Self.listWindowsFixture)
        #expect(windows.count == 2)
    }

    @Test func mapsSnakeCaseFieldsOntoFirstWindowProperties() throws {
        let windows = try CuaDriverClient.decodeWindows(from: Self.listWindowsFixture)
        let chrome = try #require(windows.first)

        #expect(chrome.appName == "Google Chrome")        // app_name -> appName
        #expect(chrome.title == "Clay - New Tab")          // title -> title
        #expect(chrome.pid == 501)                         // pid -> pid
        #expect(chrome.windowId == 91011)                  // window_id -> windowId
        #expect(chrome.isOnScreen == true)                 // is_on_screen -> isOnScreen
    }

    @Test func mapsBoundsObjectOntoCGRect() throws {
        let windows = try CuaDriverClient.decodeWindows(from: Self.listWindowsFixture)
        let chrome = try #require(windows.first)

        #expect(chrome.bounds.origin.x == 10)
        #expect(chrome.bounds.origin.y == 20)
        #expect(chrome.bounds.size.width == 1280)
        #expect(chrome.bounds.size.height == 800)
    }

    @Test func decodesSecondWindowIncludingFalseIsOnScreen() throws {
        let windows = try CuaDriverClient.decodeWindows(from: Self.listWindowsFixture)
        let finder = windows[1]

        #expect(finder.appName == "Finder")
        #expect(finder.pid == 600)
        #expect(finder.windowId == 12)
        #expect(finder.isOnScreen == false)
        #expect(finder.bounds.size.width == 640)
        #expect(finder.bounds.size.height == 480)
    }

    @Test func emptyWindowsArrayDecodesToEmptyResult() throws {
        let data = Data(#"{"windows":[],"current_space_id":1}"#.utf8)
        let windows = try CuaDriverClient.decodeWindows(from: data)
        #expect(windows.isEmpty)
    }

    @Test func leniencyDefaultsAbsentTitleAndIsOnScreen() throws {
        // CuaWindow's custom decoder is lenient: absent title -> "", absent
        // is_on_screen -> false.
        let data = Data(#"""
        {
          "windows": [
            {
              "app_name": "Safari",
              "pid": 700,
              "window_id": 34,
              "bounds": { "x": 0, "y": 0, "width": 100, "height": 200 }
            }
          ]
        }
        """#.utf8)
        let windows = try CuaDriverClient.decodeWindows(from: data)
        let safari = try #require(windows.first)

        #expect(safari.appName == "Safari")
        #expect(safari.title == "")
        #expect(safari.isOnScreen == false)
    }

    @Test func malformedPayloadThrowsDecodeFailed() {
        // Missing the required `windows` key -> decode fails.
        let data = Data(#"{"current_space_id":3}"#.utf8)
        #expect(throws: CuaDriverError.self) {
            _ = try CuaDriverClient.decodeWindows(from: data)
        }
    }

    @Test func nonJSONPayloadThrowsDecodeFailed() {
        let data = Data("not json at all".utf8)
        #expect(throws: CuaDriverError.self) {
            _ = try CuaDriverClient.decodeWindows(from: data)
        }
    }
}

// MARK: - CuaObservation field/key mapping (get_window_state payload)

@MainActor
struct CuaObservationDecodingTests {

    /// Mirror of the driver's private `get_window_state` wire struct, declaring
    /// the EXACT same snake_case CodingKeys the production code uses. Decoding a
    /// realistic fixture through this and constructing a CuaObservation proves the
    /// snake_case -> Swift-property mapping (tree_markdown, element_count,
    /// screenshot_file_path) that getWindowState(...) relies on.
    private struct WireGetWindowStateResponse: Decodable {
        let treeMarkdown: String
        let elementCount: Int
        let screenshotFilePath: String?

        enum CodingKeys: String, CodingKey {
            case treeMarkdown = "tree_markdown"
            case elementCount = "element_count"
            case screenshotFilePath = "screenshot_file_path"
        }
    }

    private func observation(from data: Data) throws -> CuaObservation {
        let raw = try JSONDecoder().decode(WireGetWindowStateResponse.self, from: data)
        return CuaObservation(
            treeMarkdown: raw.treeMarkdown,
            elementCount: raw.elementCount,
            screenshotFilePath: raw.screenshotFilePath
        )
    }

    @Test func mapsSnakeCaseGetWindowStateFieldsOntoObservation() throws {
        let data = Data(#"""
        {
          "tree_markdown": "# Window\n- [element_index 0] Button \"OK\"\n- [element_index 1] TextField",
          "element_count": 2,
          "screenshot_file_path": "/tmp/run/shot.png"
        }
        """#.utf8)

        let observation = try observation(from: data)

        #expect(observation.treeMarkdown == "# Window\n- [element_index 0] Button \"OK\"\n- [element_index 1] TextField")
        #expect(observation.elementCount == 2)
        #expect(observation.screenshotFilePath == "/tmp/run/shot.png")
    }

    @Test func absentScreenshotPathDecodesToNil() throws {
        // AX-only walks omit screenshot_file_path entirely -> optional stays nil.
        let data = Data(#"""
        {
          "tree_markdown": "# Window\n- [element_index 0] StaticText",
          "element_count": 1
        }
        """#.utf8)

        let observation = try observation(from: data)

        #expect(observation.treeMarkdown == "# Window\n- [element_index 0] StaticText")
        #expect(observation.elementCount == 1)
        #expect(observation.screenshotFilePath == nil)
    }

    @Test func explicitNullScreenshotPathDecodesToNil() throws {
        let data = Data(#"""
        {
          "tree_markdown": "",
          "element_count": 0,
          "screenshot_file_path": null
        }
        """#.utf8)

        let observation = try observation(from: data)

        #expect(observation.treeMarkdown == "")
        #expect(observation.elementCount == 0)
        #expect(observation.screenshotFilePath == nil)
    }
}
