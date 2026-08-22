import AppKit
import SwiftUI

enum RemixIconName: String {
    case loader = "loader-4-line"
    case microphoneOff = "mic-off-line"
    case warning = "error-warning-line"
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
