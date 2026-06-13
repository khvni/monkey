//
//  MonkeybotHUDView.swift
//  leanring-buddy
//
//  Floating heads-up display for the Monkeybot autonomous agent. Binds to a
//  `MonkeyAgentLoop` via @ObservedObject and renders its `MonkeyLoopState`:
//  product name, current task, target app/window, step count, last action,
//  run state (Listening hands-free / Running / Idle), a Stop button, and a
//  Save-Trace indicator showing the run's trace directory.
//
//  Visuals reuse the shared `DS` design tokens (see DesignSystem.swift) so the
//  HUD matches the rest of the dark Clicky aesthetic. The panel chrome (corner
//  radius + two-shadow stack) is copied verbatim from
//  CompanionPanelView.panelBackground.
//
//  Pure presentation. The only side effect is the Stop button calling
//  `loop.stop()` (cooperative cancel per FILE 6 contract).
//

import SwiftUI
import AppKit

// MARK: - Monkeybot HUD

/// Floating panel that mirrors the live state of a `MonkeyAgentLoop`.
///
/// The loop owns `@Published private(set) var state: MonkeyLoopState`; this view
/// observes it and re-renders on every published change. Hands-free voice state
/// is NOT part of `MonkeyLoopState` (it lives on `CompanionManager`), so the
/// integration layer passes it in via `isHandsFreeListening` to let the HUD
/// distinguish "Listening (hands-free)" from "Running" / "Idle".
struct MonkeybotHUDView: View {

    /// The agent loop driving this HUD. Re-renders whenever `loop.state` changes.
    @ObservedObject var loop: MonkeyAgentLoop

    /// When true, the HUD shows the hands-free "Listening" state (continuous
    /// dictation is active and the agent has not yet started running). Supplied
    /// by the integration layer from `CompanionManager.isHandsFreeModeActive`.
    var isHandsFreeListening: Bool = false

    /// Feature 3c — whether a saved Monkeybot run exists to re-run. Supplied by
    /// the integration layer from `CompanionManager.hasSavedRunToRerun`. When
    /// false (or no `onRerunLastSavedRun` handler is given) the re-run control is
    /// hidden, so the HUD looks identical to before on a fresh install.
    var canRerunLastSavedRun: Bool = false

    /// Feature 3c — invoked when the user taps "Re-run last saved workflow".
    /// Supplied by the integration layer to call
    /// `CompanionManager.rerunLastSavedRun()`. Nil hides the control entirely.
    var onRerunLastSavedRun: (() -> Void)? = nil

    /// Optional close handler for the panel chrome's dismiss button. When nil the
    /// close button is hidden.
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            divider
            detailRows
            pendingUserQuestionCallout
            failureBanner
            rerunRow
            divider
            footer
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.lg)
        .frame(width: 320)
        .background(panelBackground)
        .animation(.easeInOut(duration: DS.Animation.normal), value: loop.state.isRunning)
        .animation(.easeInOut(duration: DS.Animation.normal), value: isHandsFreeListening)
        .animation(.easeInOut(duration: DS.Animation.normal), value: canRerunLastSavedRun)
    }

    // MARK: - Re-run last saved workflow (Feature 3c)

    /// Whether the "Re-run last saved workflow" control should be shown at all:
    /// only when the integration layer supplied a handler AND a saved run exists.
    /// Absent both, the HUD renders exactly as it did before this feature.
    private var showsRerunControl: Bool {
        onRerunLastSavedRun != nil && canRerunLastSavedRun
    }

    /// A full-width, low-emphasis button that re-runs the most recent saved
    /// Monkeybot workflow. Hidden when no saved run exists or no handler is given;
    /// disabled (dimmed) while a run is already in progress so it never fights the
    /// live loop. Built with DS tokens + a pointer cursor, matching the HUD's
    /// compact detail-card treatment rather than the larger DS button styles.
    @ViewBuilder
    private var rerunRow: some View {
        if showsRerunControl {
            Button(action: { onRerunLastSavedRun?() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Re-run last saved workflow")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundColor(loop.state.isRunning ? DS.Colors.textTertiary : DS.Colors.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: !loop.state.isRunning)
            .disabled(loop.state.isRunning)
            .opacity(loop.state.isRunning ? 0.5 : 1.0)
            .help("Re-run the most recent saved workflow (re-decides each step against the live UI)")
        }
    }

    // MARK: - Header (product name + status pill + close)

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            // Animated status dot — color encodes the current run state.
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            Text("Monkeybot")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: DS.Spacing.sm)

            statusPill

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(DS.Colors.surface2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    /// Compact pill summarizing the run state next to the product name.
    private var statusPill: some View {
        Text(statusText)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(statusColor)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(statusColor.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(statusColor.opacity(0.25), lineWidth: 0.5)
            )
    }

    // MARK: - Detail rows

    private var detailRows: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            detailRow(label: "Task", value: taskText, valueLineLimit: 2)
            detailRow(label: "Target", value: targetText)
            detailRow(label: "Step", value: stepText, help: stepDetail)
            detailRow(label: "Last action", value: lastActionText, valueLineLimit: 2, help: rawLastActionText)
        }
    }

    /// One label/value row rendered on a `surface2` card with a subtle border,
    /// matching the row treatment used elsewhere in the panel.
    private func detailRow(label: String, value: String, valueLineLimit: Int = 1, help: String? = nil) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 78, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(valueLineLimit)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        // Carry the untruncated / raw detail (e.g. the full status line with its
        // AX index) on hover so humanizing the visible text never hides it.
        .help(help ?? "")
    }

    // MARK: - Pending question callout + failure banner

    /// Prominent amber callout surfaced only when the loop paused to ask the user
    /// a question (an `ask_user` action). Shows the full question text (up to 3
    /// lines) so the user knows what the agent needs before continuing.
    @ViewBuilder
    private var pendingUserQuestionCallout: some View {
        if let pendingUserQuestion = loop.state.pendingUserQuestion,
           !pendingUserQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.warningText)

                Text(pendingUserQuestion)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.warning.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    /// Red error banner surfaced only when the run ended in an unrecoverable
    /// failure. Truncates the inline text but carries the full message via `.help`
    /// so a long failure reason stays accessible on hover.
    @ViewBuilder
    private var failureBanner: some View {
        if isFailed, let failureMessage = loop.state.failureMessage {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.destructiveText)

                Text(failureMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.destructive.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.destructive.opacity(0.35), lineWidth: 0.5)
            )
            .help(failureMessage)
        }
    }

    // MARK: - Footer (Save Trace indicator + Stop button)

    private var footer: some View {
        HStack(alignment: .center, spacing: DS.Spacing.md) {
            saveTraceIndicator
            Spacer(minLength: DS.Spacing.sm)
            stopButton
        }
    }

    /// Shows where the trace for the current run is being written, or a saved
    /// checkmark once the loop has produced a trace directory.
    private var saveTraceIndicator: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: hasTrace ? "checkmark.circle.fill" : "tray.and.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(hasTrace ? DS.Colors.success : DS.Colors.textTertiary)

                Text(hasTrace ? "Trace saved" : "Save Trace")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)
            }

            if let directory = loop.state.traceDirectory, !directory.isEmpty {
                Text(traceDisplayPath(directory))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stopButton: some View {
        Button(action: { loop.stop() }) {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(loop.state.isRunning ? DS.Colors.textOnAccent : DS.Colors.destructiveText)
        }
        .buttonStyle(.plain)
        .dsDestructiveButtonStyle()
        .pointerCursor()
        .disabled(!loop.state.isRunning)
        .opacity(loop.state.isRunning ? 1.0 : 0.5)
    }

    // MARK: - Derived display values

    /// Whether the most recent run ended in an unrecoverable failure.
    private var isFailed: Bool {
        if let failureMessage = loop.state.failureMessage {
            return !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    /// Whether the loop paused to ask the user a question (an `ask_user` action).
    private var hasPendingUserQuestion: Bool {
        if let pendingUserQuestion = loop.state.pendingUserQuestion {
            return !pendingUserQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    /// Whether the run halted because it hit the step limit, detected from the
    /// status line the loop publishes when it terminates that way.
    private var didReachStepLimit: Bool {
        loop.state.statusLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("step limit reached")
    }

    /// Whether the run was explicitly stopped by the user, detected from the
    /// status line the loop publishes after a cooperative cancel.
    private var wasStopped: Bool {
        loop.state.statusLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .contains("stopped")
    }

    /// Whether a finished (not running) run produced a result summary, used to
    /// distinguish a completed run ("Done") from an untouched idle state.
    private var hasCompletedSummary: Bool {
        // A trace directory is only ever set after a run actually executed, so its
        // presence on a not-running loop means the run reached a terminal "Done".
        hasTrace
    }

    /// Current run state. Terminal states (Failed / Needs you / Step limit /
    /// Stopped / Done) are derived from the loop state so a finished-but-not-idle
    /// run no longer shows a misleading green "Idle" pill. While the loop is
    /// actively running it always reads "Running"; hands-free listening before a
    /// run starts reads "Listening".
    private var statusText: String {
        if loop.state.isRunning {
            return "Running"
        }
        if isHandsFreeListening {
            return "Listening"
        }
        if isFailed {
            return "Failed"
        }
        if hasPendingUserQuestion {
            return "Needs you"
        }
        if didReachStepLimit {
            return "Step limit"
        }
        if wasStopped {
            return "Stopped"
        }
        if hasCompletedSummary {
            return "Done"
        }
        return "Idle"
    }

    /// Status-dot / pill color. Running & listening use blue400; a failed run uses
    /// DS destructive red; a run awaiting the user or stopped at a limit uses DS
    /// warning amber; a completed or fresh-idle run uses success green.
    private var statusColor: Color {
        if loop.state.isRunning || isHandsFreeListening {
            return DS.Colors.blue400
        }
        if isFailed {
            return DS.Colors.destructive
        }
        if hasPendingUserQuestion || didReachStepLimit {
            return DS.Colors.warning
        }
        return DS.Colors.success
    }

    private var taskText: String {
        let task = loop.state.task.trimmingCharacters(in: .whitespacesAndNewlines)
        return task.isEmpty ? "—" : task
    }

    private var targetText: String {
        let target = loop.state.targetApplication.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? "—" : target
    }

    /// "n / max", with a humanized status line appended when present (e.g.
    /// "3 / 20 · Clicking" rather than the raw "3 / 20 · clicking [12]"). The
    /// full raw status (with its AX index) is preserved in `stepDetail` for hover.
    private var stepText: String {
        let count = "\(loop.state.stepNumber) / \(loop.state.maxSteps)"
        let status = humanizedAction(loop.state.statusLine)
        return status.isEmpty ? count : "\(count)  ·  \(status)"
    }

    /// Full, untruncated step detail surfaced on hover: the raw status line
    /// (including the trailing ` [N]` AX index) appended to the step count.
    private var stepDetail: String {
        let count = "\(loop.state.stepNumber) / \(loop.state.maxSteps)"
        let status = loop.state.statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? count : "\(count)  ·  \(status)"
    }

    /// Humanized last action for display: title-cased verb with the trailing
    /// ` [N]` AX index stripped. The raw text remains available via `rawLastActionText`.
    private var lastActionText: String {
        let humanized = humanizedAction(loop.state.lastActionSummary)
        return humanized.isEmpty ? "—" : humanized
    }

    /// The raw, untruncated last-action summary surfaced on hover.
    private var rawLastActionText: String {
        let raw = loop.state.lastActionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "—" : raw
    }

    /// Humanize a loop action/status string for display: strip a trailing ` [N]`
    /// AX element index and title-case the leading verb (e.g. "clicking [12]" →
    /// "Clicking"). Anything after the first whitespace token is left untouched so
    /// human-readable suffixes (labels, targets) survive intact.
    private func humanizedAction(_ rawAction: String) -> String {
        var action = rawAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return "" }

        // Strip a trailing AX element index like " [12]" used internally for
        // addressing — it is noise for a human reading the HUD.
        if let bracketRange = action.range(of: #"\s*\[\d+\]\s*$"#, options: .regularExpression) {
            action.removeSubrange(bracketRange)
        }
        action = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else { return "" }

        // Title-case only the leading verb so trailing detail (targets, labels)
        // keeps its original casing.
        if let firstSpaceIndex = action.firstIndex(where: { $0 == " " }) {
            let verb = String(action[..<firstSpaceIndex]).capitalized
            let remainder = String(action[firstSpaceIndex...])
            return verb + remainder
        }
        return action.capitalized
    }

    private var hasTrace: Bool {
        if let directory = loop.state.traceDirectory {
            return !directory.isEmpty
        }
        return false
    }

    /// Shorten a long absolute trace path to the trailing run-folder segments so
    /// it stays readable inside the narrow footer.
    private func traceDisplayPath(_ path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    // MARK: - Visual helpers

    private var divider: some View {
        Rectangle()
            .fill(DS.Colors.borderSubtle)
            .frame(height: 0.5)
    }

    /// Panel chrome copied verbatim from CompanionPanelView.panelBackground:
    /// background fill + continuous extra-large corner + two-shadow stack.
    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}
