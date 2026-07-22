import AppKit
import SwiftUI

struct UsageThemeView: View {
    let theme: UsageTheme
    let usedPercentage: Double
    var size: CGFloat = 28

    private let store = UsageThemeStore()

    var body: some View {
        Group {
            if let frameName = theme.frameName(for: usedPercentage),
               let image = NSImage(contentsOf: store.imageURL(theme: theme, frameName: frameName)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .id(frameName)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.3), value: theme.frameName(for: usedPercentage))
        .accessibilityLabel("Usage \(Int(usedPercentage.rounded())) percent")
    }
}
