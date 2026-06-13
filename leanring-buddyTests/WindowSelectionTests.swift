//
//  WindowSelectionTests.swift
//  leanring-buddyTests
//
//  Covers MonkeyAgentLoop.selectTargetWindow(from:) — the demo-critical
//  Chrome-window-selection heuristic. Pure/deterministic logic only: no
//  Process exec, no network, no live cua-driver, no real screenshots.
//

import Foundation
import Testing
@testable import leanring_buddy

// @MainActor: selectTargetWindow is isolated to MonkeyAgentLoop (@MainActor), and
// the test target does not default to MainActor isolation, so the suite must opt in.
@MainActor
struct WindowSelectionTests {

    // MARK: - Fixture builder

    /// `CuaWindow` only exposes `init(from decoder:)` (no memberwise init), so
    /// build fixtures the way the real driver does: by decoding the driver's
    /// snake_case JSON record. Bounds are a top-left-origin x/y/width/height
    /// object, exactly matching `list_windows` output.
    private static func makeWindow(
        appName: String,
        title: String,
        pid: Int = 1000,
        windowId: Int = 1,
        isOnScreen: Bool,
        x: Double = 0,
        y: Double = 0,
        width: Double,
        height: Double
    ) -> CuaWindow {
        let json: [String: Any] = [
            "app_name": appName,
            "title": title,
            "pid": pid,
            "window_id": windowId,
            "is_on_screen": isOnScreen,
            "bounds": [
                "x": x,
                "y": y,
                "width": width,
                "height": height,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(CuaWindow.self, from: data)
    }

    // Convenience: a full-size, on-screen Chrome browser frame.
    private static func chrome(
        _ title: String,
        windowId: Int = 1,
        isOnScreen: Bool = true,
        width: Double = 1440,
        height: Double = 900
    ) -> CuaWindow {
        makeWindow(
            appName: "Google Chrome",
            title: title,
            windowId: windowId,
            isOnScreen: isOnScreen,
            width: width,
            height: height
        )
    }

    // A tiny off-screen helper surface: empty title, not on-screen, a few px.
    // These dominate a live `list_windows` and must never be chosen over a real
    // frame.
    private static func helper(windowId: Int, width: Double = 4, height: Double = 4) -> CuaWindow {
        makeWindow(
            appName: "Google Chrome",
            title: "",
            windowId: windowId,
            isOnScreen: false,
            width: width,
            height: height
        )
    }

    // MARK: - 1. No Chrome windows / empty input -> nil

    @Test func emptyInputReturnsNil() {
        #expect(MonkeyAgentLoop.selectTargetWindow(from: []) == nil)
    }

    @Test func noChromeWindowsReturnsNil() {
        let windows = [
            Self.makeWindow(appName: "Safari", title: "Clay", isOnScreen: true, width: 1440, height: 900),
            Self.makeWindow(appName: "Finder", title: "Downloads", isOnScreen: true, width: 800, height: 600),
            Self.makeWindow(appName: "Xcode", title: "leanring-buddy", isOnScreen: true, width: 1200, height: 800),
        ]
        #expect(MonkeyAgentLoop.selectTargetWindow(from: windows) == nil)
    }

    // MARK: - 2. Title priority: a "Clay" window beats a larger non-Clay window

    @Test func clayTitleBeatsLargerNonClayWindow() {
        // The non-Clay window is dramatically larger by area, yet the Clay-titled
        // window must still win on title priority.
        let bigNonClay = Self.chrome("New Tab", windowId: 10, width: 3840, height: 2160)
        let smallClay = Self.chrome("Clay — CRM", windowId: 11, width: 800, height: 600)

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [bigNonClay, smallClay])
        #expect(picked?.windowId == smallClay.windowId)
        #expect(picked?.title == "Clay — CRM")
    }

    @Test func clayMatchIsCaseInsensitiveAndSubstring() {
        let bigNonClay = Self.chrome("Dashboard", windowId: 20, width: 3000, height: 2000)
        // Lowercase + embedded mid-title to exercise the substring/case rules.
        let clayWindow = Self.chrome("My clay workspace", windowId: 21, width: 600, height: 400)

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [bigNonClay, clayWindow])
        #expect(picked?.windowId == clayWindow.windowId)
    }

    // MARK: - 3. Among multiple Clay-titled windows, largest by area wins

    @Test func largestClayWindowWinsAmongClayWindows() {
        let smallClay = Self.chrome("Clay (tab 1)", windowId: 30, width: 400, height: 300) // 120_000
        let largeClay = Self.chrome("Clay (tab 2)", windowId: 31, width: 1600, height: 1000) // 1_600_000
        let midClay = Self.chrome("Clay (tab 3)", windowId: 32, width: 800, height: 600)   // 480_000

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [smallClay, largeClay, midClay])
        #expect(picked?.windowId == largeClay.windowId)
    }

    // MARK: - 4. No Clay title: real on-screen titled frame beats off-screen helpers
    //         (replicates the live probe: 1 real window + several empty helpers)

    @Test func realOnScreenTitledWindowBeatsOffScreenHelpers() {
        // Live-probe-shaped input: a single real browser frame plus a swarm of
        // tiny, empty-title, off-screen helper windows. The real frame must win.
        let realWindow = Self.chrome(
            "Feed | LinkedIn",
            windowId: 100,
            isOnScreen: true,
            width: 1512,
            height: 944
        )
        let helpers = (1...6).map { Self.helper(windowId: 200 + $0) }

        var windows = helpers
        // Insert the real window in the middle so order can't be doing the work.
        windows.insert(realWindow, at: 3)

        let picked = MonkeyAgentLoop.selectTargetWindow(from: windows)
        #expect(picked?.windowId == realWindow.windowId)
        #expect(picked?.title == "Feed | LinkedIn")
        #expect(picked?.isOnScreen == true)
    }

    @Test func onScreenTitledWindowChosenEvenWhenAnOffScreenHelperIsLargerByArea() {
        // An off-screen helper with no title can be huge by area; it must still
        // lose to a smaller on-screen titled frame because of the on-screen +
        // non-empty-title gate.
        let realWindow = Self.chrome("Feed | LinkedIn", windowId: 100, isOnScreen: true, width: 1000, height: 700)
        let hugeOffScreenHelper = Self.makeWindow(
            appName: "Google Chrome",
            title: "",
            windowId: 101,
            isOnScreen: false,
            width: 5000,
            height: 5000
        )

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [hugeOffScreenHelper, realWindow])
        #expect(picked?.windowId == realWindow.windowId)
    }

    @Test func largestOnScreenTitledWindowWinsAmongRealFrames() {
        let smallReal = Self.chrome("GitHub", windowId: 110, isOnScreen: true, width: 800, height: 600)
        let bigReal = Self.chrome("Feed | LinkedIn", windowId: 111, isOnScreen: true, width: 1512, height: 944)
        let helpers = (1...4).map { Self.helper(windowId: 300 + $0) }

        let picked = MonkeyAgentLoop.selectTargetWindow(from: helpers + [smallReal, bigReal])
        #expect(picked?.windowId == bigReal.windowId)
    }

    // MARK: - 5. Last resort: only helper windows -> largest-by-area (not nil)

    @Test func onlyHelperWindowsReturnsLargestByAreaNotNil() {
        // No Clay title, nothing on-screen with a non-empty title — the heuristic
        // must still return a window (the largest helper), never nil, because
        // there ARE Chrome windows.
        let small = Self.helper(windowId: 400, width: 4, height: 4)        // 16
        let largest = Self.helper(windowId: 401, width: 20, height: 30)    // 600
        let mid = Self.helper(windowId: 402, width: 10, height: 10)        // 100

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [small, largest, mid])
        #expect(picked != nil)
        #expect(picked?.windowId == largest.windowId)
    }

    @Test func lastResortConsidersOnScreenButEmptyTitledWindows() {
        // On-screen but empty-title windows don't pass the step-3 gate, so they
        // fall through to the largest-overall fallback alongside off-screen ones.
        let onScreenEmpty = Self.makeWindow(
            appName: "Google Chrome",
            title: "   ",                       // whitespace-only => trimmed empty
            windowId: 410,
            isOnScreen: true,
            width: 30,
            height: 30                          // 900
        )
        let offScreenHelper = Self.helper(windowId: 411, width: 50, height: 50) // 2500 (largest overall)

        let picked = MonkeyAgentLoop.selectTargetWindow(from: [onScreenEmpty, offScreenHelper])
        #expect(picked?.windowId == offScreenHelper.windowId)
    }
}
