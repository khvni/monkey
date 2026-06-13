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

    /// Optional close handler for the panel chrome's dismiss button. When nil the
    /// close button is hidden.
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            header
            divider
            detailRows
            divider
            footer
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.lg)
        .frame(width: 320)
        .background(panelBackground)
        .animation(.easeInOut(duration: DS.Animation.normal), value: loop.state.isRunning)
        .animation(.easeInOut(duration: DS.Animation.normal), value: isHandsFreeListening)
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
            detailRow(label: "Step", value: stepText)
            detailRow(label: "Last action", value: lastActionText, valueLineLimit: 2)
        }
    }

    /// One label/value row rendered on a `surface2` card with a subtle border,
    /// matching the row treatment used elsewhere in the panel.
    private func detailRow(label: String, value: String, valueLineLimit: Int = 1) -> some View {
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

    /// Current run state, distinguishing hands-free listening from an active run.
    private var statusText: String {
        if loop.state.isRunning {
            return "Running"
        }
        if isHandsFreeListening {
            return "Listening"
        }
        return "Idle"
    }

    /// Status-dot / pill color per architect DS facts: running & listening use
    /// blue400, idle/done use success green.
    private var statusColor: Color {
        if loop.state.isRunning || isHandsFreeListening {
            return DS.Colors.blue400
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

    /// "n / max", with the status line appended when present (e.g. "3 / 20 · clicking [12]").
    private var stepText: String {
        let count = "\(loop.state.stepNumber) / \(loop.state.maxSteps)"
        let status = loop.state.statusLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? count : "\(count)  ·  \(status)"
    }

    private var lastActionText: String {
        let last = loop.state.lastActionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return last.isEmpty ? "—" : last
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
