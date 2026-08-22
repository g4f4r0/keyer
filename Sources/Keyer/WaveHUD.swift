import AppKit
import SwiftUI
import WaveCore

@MainActor
final class WaveHUDModel: ObservableObject {
    @Published var state: WaveState = .ready
    @Published var level: Float = 0
    @Published var message: String?
    @Published var approachingLimit = false
    @Published var isVisible = false
}

struct WaveHUDView: View {
    private enum Presentation: Hashable {
        case recording
        case processing
        case message
    }

    @ObservedObject var model: WaveHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            recordingContent
                .opacity(presentation == .recording ? 1 : 0)
                .animation(contentAnimation(for: .recording), value: presentation)

            processingContent
                .opacity(presentation == .processing ? 1 : 0)
                .animation(contentAnimation(for: .processing), value: presentation)

            messageContent
                .opacity(presentation == .message ? 1 : 0)
                .animation(contentAnimation(for: .message), value: presentation)
        }
        .frame(width: targetWidth, height: 32)
        .foregroundStyle(.white)
        .background {
            Capsule()
                .fill(.black.opacity(reduceTransparency ? 0.88 : 0.48))
                .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
                .shadow(color: .black.opacity(reduceTransparency ? 0.16 : 0.22), radius: 7, y: 3)
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    model.approachingLimit && presentation == .recording
                        ? Color.orange.opacity(reduceTransparency ? 0.9 : 0.72)
                        : .clear,
                    lineWidth: 1
                )
                .padding(1)
                .blur(radius: reduceTransparency ? 0 : 0.45)
        }
        .background {
            Capsule()
                .fill(
                    model.approachingLimit && presentation == .recording
                        ? Color.orange.opacity(reduceTransparency ? 0.08 : 0.12)
                        : .clear
                )
                .padding(1)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: model.approachingLimit)
        .animation(widthAnimation, value: targetWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .frame(width: 420, height: 56)
    }

    private var recordingContent: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<13, id: \.self) { index in
                Capsule()
                    .frame(width: 2, height: barHeight(index))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: model.level)
            }
        }
        .frame(width: 80, height: 18)
    }

    private var processingContent: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: reduceMotion || !model.isVisible || presentation != .processing
        )) { context in
            RemixIcon(name: .loader, fallbackSystemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotation(at: context.date)))
        }
        .frame(width: 32, height: 32)
    }

    private var messageContent: some View {
        HStack(spacing: 6) {
            RemixIcon(
                name: isNoSpeechMessage ? .microphoneOff : .warning,
                fallbackSystemName: isNoSpeechMessage ? "mic.slash" : "exclamationmark.circle"
            )
            .frame(width: 13, height: 13)

            Text(message)
                .font(messageFont)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var presentation: Presentation {
        if model.message != nil { return .message }
        if case .recording = model.state { return .recording }
        return .processing
    }

    private var message: String {
        model.message ?? "Dictation failed"
    }

    private var targetWidth: CGFloat {
        switch presentation {
        case .recording: 80
        case .processing: 32
        case .message:
            min(max(ceil(messageTextWidth) + 13 + 6 + 20, 88), 390)
        }
    }

    private var messageTextWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return (message as NSString).size(withAttributes: [.font: font]).width
    }

    private var messageFont: Font {
        .system(size: 12, weight: .medium)
    }

    private var isNoSpeechMessage: Bool {
        message.localizedCaseInsensitiveContains("no speech")
    }

    private var accessibilityLabel: String {
        switch presentation {
        case .recording: "Recording, press Escape to cancel"
        case .processing: "Processing dictation"
        case .message: message
        }
    }

    private var widthAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24)
    }

    private func contentAnimation(for content: Presentation) -> Animation? {
        guard !reduceMotion else { return nil }
        let delay = presentation == content ? 0.1 : 0
        return .easeOut(duration: 0.1).delay(delay)
    }

    private func rotation(at date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let weights: [Float] = [0.38, 0.54, 0.72, 0.9, 0.62, 0.82, 1, 0.76, 0.92, 0.66, 0.8, 0.56, 0.4]
        let level = min(max(model.level, 0.03), 1)
        return CGFloat(3 + level * weights[index] * 15)
    }
}

@MainActor
final class WaveHUDPanel {
    private static let panelSize = NSSize(width: 420, height: 56)
    private static let hudHeight: CGFloat = 32
    private static let hiddenDockBottomGap: CGFloat = 32
    private static let visibleDockGap: CGFloat = 16
    private let panel: NSPanel
    private let model: WaveHUDModel

    init(model: WaveHUDModel) {
        self.model = model
        panel = NSPanel(contentRect: .init(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentViewController = NSHostingController(rootView: WaveHUDView(model: model))
    }

    func show() {
        model.isVisible = true
        if panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let verticalInset = (Self.panelSize.height - Self.hudHeight) / 2
        let visualBottom = max(
            screen.frame.minY + Self.hiddenDockBottomGap,
            screen.visibleFrame.minY + Self.visibleDockGap
        )
        let origin = NSPoint(x: screen.visibleFrame.midX - Self.panelSize.width / 2,
                             y: visualBottom - verticalInset)
        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: false)
        panel.orderFrontRegardless()
    }

    func hide() {
        model.isVisible = false
        panel.orderOut(nil)
    }
}
