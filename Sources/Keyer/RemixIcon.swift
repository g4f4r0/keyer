import AppKit
import SwiftUI

enum RemixIconName: String {
    case close = "close-line"
    case delete = "delete-bin-6-line"
    case folderOpen = "folder-open-line"
    case loader = "loader-line"
    case microphoneOff = "mic-off-line"
    case pause = "pause-fill"
    case play = "play-fill"
    case refresh = "refresh-line"
    case stop = "stop-fill"
    case video = "video-line"
}

enum KeyerStatusTone {
    case success
    case warning
    case error
}

struct KeyerStatusDot: View {
    let tone: KeyerStatusTone

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
    }

    private var color: Color {
        switch tone {
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(red: 1, green: 0.72, blue: 0.12)
        case .error: Color(red: 1, green: 0.2, blue: 0.14)
        }
    }
}

struct RemixIcon: View {
    let name: RemixIconName
    let fallbackSystemName: String

    var body: some View {
        if let image = Self.image(named: name) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
        } else {
            Image(systemName: fallbackSystemName)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    private static func image(named name: RemixIconName) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name.rawValue,
            withExtension: "svg",
            subdirectory: "RemixIcons"
        ), let source = NSImage(contentsOf: url),
              let image = source.copy() as? NSImage else { return nil }
        image.isTemplate = true
        return image
    }
}

struct RemixSpinner: View {
    let size: CGFloat
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: reduceMotion || !isActive
        )) { context in
            RemixIcon(name: .loader, fallbackSystemName: "progress.indicator")
                .frame(width: size, height: size)
                .rotationEffect(.degrees(reduceMotion ? 0 : rotation(at: context.date)))
        }
        .frame(width: size, height: size)
    }

    private func rotation(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) * 400
    }
}

struct KeyerPillBackground: View {
    let castsShadow: Bool
    var showsSoftBorder = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Capsule()
            .fill(.black.opacity(reduceTransparency ? 0.88 : 0.48))
            .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
            .overlay {
                if showsSoftBorder {
                    Capsule()
                        .strokeBorder(
                            .white.opacity(reduceTransparency ? 0.14 : 0.1),
                            lineWidth: 0.5
                        )
                }
            }
            .shadow(
                color: castsShadow
                    ? .black.opacity(reduceTransparency ? 0.16 : 0.22)
                    : .clear,
                radius: castsShadow ? 7 : 0,
                y: castsShadow ? 3 : 0
            )
    }
}
