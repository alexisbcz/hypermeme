import AppKit
import SwiftUI

/// Hypermeme's surfaces. Dark mode is true black with strong text, so memes are the brightest
/// thing on screen, and solid colors keep it that way whatever is behind the panel.
extension Color {
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Behind everything.
    static let canvas = adaptive(dark: .black, light: .white)
    /// The sidebar, clearly lifted off the main view.
    static let sidebar = adaptive(dark: NSColor(white: 0.14, alpha: 1), light: NSColor(white: 0.91, alpha: 1))
    /// Empty thumbnails and other quiet fills.
    static let raised = adaptive(dark: NSColor(white: 0.1, alpha: 1), light: NSColor(white: 0.95, alpha: 1))
    /// Secondary text, well above the system's dim gray on black.
    static let subdued = adaptive(dark: NSColor(white: 0.74, alpha: 1), light: NSColor(white: 0.38, alpha: 1))
    static let hairline = adaptive(dark: NSColor(white: 1, alpha: 0.2), light: NSColor(white: 0, alpha: 0.14))
}

struct Hairline: View {
    var body: some View { Color.hairline.frame(height: 1) }
}
