//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// Posted to explicitly hide the Monkeybot HUD (e.g. its close button).
    static let monkeybotDismissHUD = Notification.Name("monkeybotDismissHUD")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    // MARK: - Monkeybot HUD

    /// Floating HUD panel for the Monkeybot agent run. Persistent for the
    /// duration of a run; NOT dismissed on outside click (unlike the menu panel).
    private var monkeybotHUDPanel: NSPanel?
    private let monkeybotHUDPanelWidth: CGFloat = 320
    private var monkeybotHUDCancellables: Set<AnyCancellable> = []
    private var monkeybotDismissHUDObserver: NSObjectProtocol?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        monkeybotDismissHUDObserver = NotificationCenter.default.addObserver(
            forName: .monkeybotDismissHUD,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hideMonkeybotHUD()
        }

        observeMonkeybotState()
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = monkeybotDismissHUDObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Monkeybot HUD Lifecycle

    /// True once the loop-state subscription has been wired. Avoids touching the
    /// lazy `monkeyAgentLoop` (and its cua-driver binary search) until Monkeybot
    /// mode is actually enabled.
    private var hasWiredMonkeybotLoopObservation = false

    /// Wires HUD observation deferred to first Monkeybot-mode enable. We watch
    /// only the lightweight `monkeybotModeEnabled` flag at launch; the heavier
    /// loop-state subscription (which forces the lazy loop + binary search) is
    /// installed the first time Monkeybot is turned on.
    private func observeMonkeybotState() {
        // Hands-free listening is independent of cua-driver and cheap to observe,
        // so subscribe to it eagerly to surface the HUD's "Listening" state.
        companionManager.$isHandsFreeModeActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isListening in
                guard let self else { return }
                // Only surface the HUD for hands-free when Monkeybot mode is on,
                // so a plain-dictation user never triggers the lazy loop / binary
                // search and never sees an agent HUD they didn't ask for.
                guard self.companionManager.monkeybotModeEnabled else { return }
                self.refreshMonkeybotHUDContent()
                if isListening {
                    self.showMonkeybotHUD()
                } else if !self.isMonkeybotLoopRunning {
                    self.scheduleMonkeybotHUDHideIfIdle()
                }
            }
            .store(in: &monkeybotHUDCancellables)

        // Install the loop-state subscription only once Monkeybot is enabled.
        companionManager.$monkeybotModeEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self, enabled else { return }
                self.wireMonkeybotLoopObservationIfNeeded()
            }
            .store(in: &monkeybotHUDCancellables)
    }

    /// Subscribes to the agent loop's running state so the HUD auto-shows on a
    /// run and auto-hides when idle. Idempotent and lazy — only forces the loop
    /// when Monkeybot mode has been enabled.
    private func wireMonkeybotLoopObservationIfNeeded() {
        guard !hasWiredMonkeybotLoopObservation else { return }
        guard let monkeyAgentLoop = companionManager.monkeyAgentLoop else { return }
        hasWiredMonkeybotLoopObservation = true

        monkeyAgentLoop.$state
            .map(\.isRunning)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self else { return }
                if isRunning {
                    self.showMonkeybotHUD()
                } else if !self.companionManager.isHandsFreeModeActive {
                    self.scheduleMonkeybotHUDHideIfIdle()
                }
            }
            .store(in: &monkeybotHUDCancellables)
    }

    /// Rebuilds the HUD's SwiftUI root so the (non-bound) `isHandsFreeListening`
    /// value reflects the latest CompanionManager state. The agent loop's state
    /// is observed reactively, so only the hands-free flag needs this nudge.
    private func refreshMonkeybotHUDContent() {
        guard let hudPanel = monkeybotHUDPanel,
              let hostingView = hudPanel.contentView as? NSHostingView<AnyView>,
              let monkeyAgentLoop = companionManager.monkeyAgentLoop else { return }
        hostingView.rootView = AnyView(
            MonkeybotHUDView(
                loop: monkeyAgentLoop,
                isHandsFreeListening: companionManager.isHandsFreeModeActive,
                canRerunLastSavedRun: companionManager.hasSavedRunToRerun,
                onRerunLastSavedRun: { [weak companionManager] in
                    companionManager?.rerunLastSavedRun()
                },
                onClose: { NotificationCenter.default.post(name: .monkeybotDismissHUD, object: nil) }
            )
            .frame(width: monkeybotHUDPanelWidth)
        )
    }

    /// Whether the agent loop is currently running, WITHOUT forcing the lazy
    /// loop to be constructed. Returns false until the loop observation is wired.
    private var isMonkeybotLoopRunning: Bool {
        guard hasWiredMonkeybotLoopObservation else { return false }
        return companionManager.monkeyAgentLoop?.state.isRunning ?? false
    }

    /// Hides the HUD after a short grace period if nothing is running/listening.
    /// Keeps the HUD visible when there is a saved run to re-run, so the Re-run
    /// control and trace path stay reachable; the user can still close it via
    /// the HUD's close button.
    private func scheduleMonkeybotHUDHideIfIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            guard let self else { return }
            guard !self.isMonkeybotLoopRunning, !self.companionManager.isHandsFreeModeActive else { return }
            guard !self.companionManager.hasSavedRunToRerun else { return }
            self.hideMonkeybotHUD()
        }
    }

    private func showMonkeybotHUD() {
        guard companionManager.monkeyAgentLoop != nil else { return }
        let isFirstShow = monkeybotHUDPanel == nil
        if monkeybotHUDPanel == nil {
            createMonkeybotHUDPanel()
        }
        guard let hudPanel = monkeybotHUDPanel else { return }

        positionMonkeybotHUD()

        // On first show, start fully transparent so the HUD fades in instead of
        // popping in with a hard cut.
        if isFirstShow {
            hudPanel.alphaValue = 0
        }
        hudPanel.makeKeyAndOrderFront(nil)
        hudPanel.orderFrontRegardless()

        // The panel's fitting size is only accurate once its hosting view has
        // been realized on screen, so reposition after ordering front to avoid
        // clipping the footer on the very first show.
        positionMonkeybotHUD()

        if isFirstShow {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Animation.normal
                hudPanel.animator().alphaValue = 1
            }
        }
    }

    private func hideMonkeybotHUD() {
        monkeybotHUDPanel?.orderOut(nil)
    }

    private func createMonkeybotHUDPanel() {
        guard let monkeyAgentLoop = companionManager.monkeyAgentLoop else { return }

        let hudView = AnyView(
            MonkeybotHUDView(
                loop: monkeyAgentLoop,
                isHandsFreeListening: companionManager.isHandsFreeModeActive,
                canRerunLastSavedRun: companionManager.hasSavedRunToRerun,
                onRerunLastSavedRun: { [weak companionManager] in
                    companionManager?.rerunLastSavedRun()
                },
                onClose: { NotificationCenter.default.post(name: .monkeybotDismissHUD, object: nil) }
            )
            .frame(width: monkeybotHUDPanelWidth)
        )

        let hostingView = NSHostingView<AnyView>(rootView: hudView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Reuse the same NSPanel pattern as the menu bar panel (KeyablePanel).
        let hudPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: monkeybotHUDPanelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        hudPanel.isFloatingPanel = true
        hudPanel.level = .floating
        hudPanel.isOpaque = false
        hudPanel.backgroundColor = .clear
        hudPanel.hasShadow = false
        hudPanel.hidesOnDeactivate = false
        hudPanel.isExcludedFromWindowsMenu = true
        hudPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Let the user drag the HUD out of the way during a run.
        hudPanel.isMovableByWindowBackground = true
        hudPanel.titleVisibility = .hidden
        hudPanel.titlebarAppearsTransparent = true
        hudPanel.contentView = hostingView
        monkeybotHUDPanel = hudPanel
    }

    /// Positions the HUD in the bottom-right of the main screen's visible frame.
    /// Uses fittingSize so the height tracks the SwiftUI content.
    private func positionMonkeybotHUD() {
        guard let hudPanel = monkeybotHUDPanel else { return }
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let fittingSize = hudPanel.contentView?.fittingSize
            ?? CGSize(width: monkeybotHUDPanelWidth, height: 260)
        let originX = screen.maxX - monkeybotHUDPanelWidth - 16
        let originY = screen.minY + 16
        hudPanel.setFrame(
            NSRect(x: originX, y: originY, width: monkeybotHUDPanelWidth, height: fittingSize.height),
            display: true
        )
    }
}
