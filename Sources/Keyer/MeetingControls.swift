import AppKit
import SwiftUI

private enum MeetingControlSide {
    case left
    case right
}

private struct MeetingControlView: View {
    @ObservedObject var coordinator: MeetingCoordinator
    let side: MeetingControlSide

    var body: some View {
        Group {
            if side == .left {
                leftControl
            } else {
                rightControl
            }
        }
        .frame(height: 30)
        .foregroundStyle(.white)
        .padding(2)
    }

    @ViewBuilder
    private var leftControl: some View {
        switch coordinator.state {
        case .suggested:
            actionButton("Meeting?", icon: .video, fallback: "video", action: coordinator.dismissSuggestion)
                .help("Dismiss meeting suggestion")
        case .recording:
            actionButton(time, icon: .pause, fallback: "pause.fill", action: coordinator.pause)
                .help("Pause meeting")
        case .paused:
            actionButton(time, icon: .play, fallback: "play.fill", action: coordinator.resume)
                .help("Resume meeting")
        case .transcribing:
            statusLabel("Transcribing")
        case .summarizing:
            statusLabel("Summarizing")
        case .saved:
            statusLabel("Saved", dot: .success)
        case let .failed(message):
            statusLabel(message, dot: .error)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightControl: some View {
        switch coordinator.state {
        case .suggested:
            iconButton(.play, fallback: "play.fill", label: "Start meeting", action: coordinator.startMeeting)
        case .recording:
            iconButton(
                .stop,
                fallback: "stop.fill",
                label: "Stop and process meeting",
                destructive: true,
                action: coordinator.stopAndProcess
            )
        case .paused:
            iconButton(
                .delete,
                fallback: "trash",
                label: "Discard meeting",
                destructive: true,
                action: coordinator.requestDiscard
            )
        case .transcribing, .summarizing:
            RemixSpinner(size: 13)
            .frame(width: 30, height: 30)
            .meetingControlSurface()
            .accessibilityLabel("Processing meeting")
        case .saved:
            iconButton(
                .folderOpen,
                fallback: "folder",
                label: "Open meeting",
                action: coordinator.openSavedMeeting
            )
        case .failed:
            if coordinator.canRetry {
                iconButton(.refresh, fallback: "arrow.clockwise", label: "Retry meeting", action: coordinator.retry)
            } else {
                iconButton(.close, fallback: "xmark", label: "Close", action: coordinator.dismissFailure)
            }
        case .idle:
            EmptyView()
        }
    }

    private func actionButton(
        _ title: String,
        icon: RemixIconName,
        fallback: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                RemixIcon(name: icon, fallbackSystemName: fallback)
                    .frame(width: 13, height: 13)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .contentShape(.capsule)
            .meetingControlSurface()
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(MeetingControlButtonStyle())
    }

    private func iconButton(
        _ icon: RemixIconName,
        fallback: String,
        label: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RemixIcon(name: icon, fallbackSystemName: fallback)
                .frame(width: 13, height: 13)
                .foregroundStyle(destructive ? Color.destructive : .white)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
                .meetingControlSurface()
        }
        .buttonStyle(MeetingControlButtonStyle())
        .help(label)
        .accessibilityLabel(label)
    }

    private func statusLabel(
        _ title: String,
        dot: KeyerStatusTone? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if let dot {
                KeyerStatusDot(tone: dot)
            }
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
        .meetingControlSurface()
    }

    private var time: String {
        let seconds = coordinator.elapsedSeconds
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }

}

private struct MeetingControlSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            KeyerPillBackground(castsShadow: false, showsSoftBorder: true)
        }
    }
}

private extension View {
    func meetingControlSurface() -> some View {
        modifier(MeetingControlSurface())
    }
}

private struct MeetingControlButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Capsule()
                    .fill(.white.opacity(configuration.isPressed ? 0.1 : (isHovering ? 0.06 : 0)))
            }
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.14, extraBounce: 0.08),
                value: configuration.isPressed
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private extension Color {
    static let destructive = Color(nsColor: .systemRed).opacity(0.92)
}

@MainActor
final class MeetingControlsPanel {
    private static let controlHeight: CGFloat = 30
    private static let canvasInset: CGFloat = 2
    private static let panelHeight = controlHeight + canvasInset * 2
    private static let groupGap: CGFloat = 4
    private static let notchGap: CGFloat = 4
    private let leftPanel: NSPanel
    private let rightPanel: NSPanel
    private unowned let coordinator: MeetingCoordinator
    private var screenObserver: NSObjectProtocol?

    init(coordinator: MeetingCoordinator) {
        self.coordinator = coordinator
        leftPanel = Self.makePanel()
        rightPanel = Self.makePanel()
        leftPanel.contentViewController = NSHostingController(
            rootView: MeetingControlView(coordinator: coordinator, side: .left)
        )
        rightPanel.contentViewController = NSHostingController(
            rootView: MeetingControlView(coordinator: coordinator, side: .right)
        )
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func show() {
        reposition()
        leftPanel.orderFrontRegardless()
        rightPanel.orderFrontRegardless()
    }

    func hide() {
        leftPanel.orderOut(nil)
        rightPanel.orderOut(nil)
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let leftWidth = leftControlWidth
        let rightWidth: CGFloat = 30
        let menuBarHeight = max(Self.controlHeight, screen.frame.maxY - screen.visibleFrame.maxY)
        let controlY = screen.frame.maxY - menuBarHeight + (menuBarHeight - Self.controlHeight) / 2
        let panelY = controlY - Self.canvasInset

        let leftX: CGFloat
        let rightX: CGFloat
        if let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            leftX = leftArea.maxX - Self.notchGap - leftWidth - Self.canvasInset
            rightX = rightArea.minX + Self.notchGap - Self.canvasInset
        } else {
            let totalWidth = leftWidth + Self.groupGap + rightWidth
            let controlLeftX = screen.frame.midX - totalWidth / 2
            leftX = controlLeftX - Self.canvasInset
            rightX = controlLeftX + leftWidth + Self.groupGap - Self.canvasInset
        }

        leftPanel.setFrame(
            NSRect(
                x: leftX,
                y: panelY,
                width: leftWidth + Self.canvasInset * 2,
                height: Self.panelHeight
            ),
            display: leftPanel.isVisible,
            animate: false
        )
        rightPanel.setFrame(
            NSRect(
                x: rightX,
                y: panelY,
                width: rightWidth + Self.canvasInset * 2,
                height: Self.panelHeight
            ),
            display: rightPanel.isVisible,
            animate: false
        )
    }

    private var leftControlWidth: CGFloat {
        let title: String
        let font: NSFont
        let surroundingWidth: CGFloat
        switch coordinator.state {
        case .suggested:
            title = "Meeting?"
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 43
        case .recording, .paused:
            title = coordinator.elapsedSeconds >= 3_600 ? "0:00:00" : "00:00"
            font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 41
        case .transcribing:
            title = "Transcribing"
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 32
        case .summarizing:
            title = "Summarizing"
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 32
        case .saved:
            title = "Saved"
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 44
        case let .failed(message):
            title = message
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 44
        case .idle:
            title = ""
            font = .systemFont(ofSize: 12, weight: .medium)
            surroundingWidth = 0
        }
        let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
        return min(max(ceil(textWidth) + surroundingWidth, 58), 220)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 34, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
