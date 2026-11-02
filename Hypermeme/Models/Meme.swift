import Foundation

nonisolated enum MemeFont: String, Codable, CaseIterable, Identifiable, Sendable {
    case impact, arial, helvetica, comic, georgia, marker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .impact: "Impact"
        case .arial: "Arial"
        case .helvetica: "Helvetica"
        case .comic: "Comic Sans"
        case .georgia: "Georgia"
        case .marker: "Marker"
        }
    }

    var postScriptName: String {
        switch self {
        case .impact: "Impact"
        case .arial: "Arial-BoldMT"
        case .helvetica: "Helvetica-Bold"
        case .comic: "ComicSansMS-Bold"
        case .georgia: "Georgia-Bold"
        case .marker: "MarkerFelt-Wide"
        }
    }

    /// imgflip's names for its fonts.
    init(imgflip name: String?) {
        switch name?.lowercased() {
        case "impact": self = .impact
        case "helvetica": self = .helvetica
        case "comic sans ms": self = .comic
        case "georgia": self = .georgia
        case nil: self = .impact
        default: self = .arial
        }
    }
}

nonisolated enum HorizontalAlign: String, Codable, CaseIterable, Sendable { case left, center, right }
nonisolated enum VerticalAlign: String, Codable, CaseIterable, Sendable { case top, middle, bottom }

/// One piece of text on a meme. Positions are fractions of the canvas, so a box means the same
/// thing in a small preview and in the full-size export.
nonisolated struct TextBox: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var text = ""
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Degrees clockwise.
    var rotation = 0.0
    var font = MemeFont.impact
    var color = "#FFFFFF"
    var outline = "#000000"
    var allCaps = true
    var align = HorizontalAlign.center
    var verticalAlign = VerticalAlign.middle
    var shadow = false
    /// As a fraction of the canvas height. Nil lets the text grow to fill its box.
    var maxFontSize: Double?

    static func top() -> TextBox { TextBox(x: 0.03, y: 0.02, width: 0.94, height: 0.24, verticalAlign: .top) }
    static func bottom() -> TextBox { TextBox(x: 0.03, y: 0.74, width: 0.94, height: 0.24, verticalAlign: .bottom) }

    /// The boxes a template without a known layout starts with.
    static func defaults(count: Int) -> [TextBox] {
        switch count {
        case ...1: return [.top()]
        case 2: return [.top(), .bottom()]
        default:
            let height = 0.9 / Double(count)
            return (0..<count).map { index in
                TextBox(x: 0.03, y: 0.05 + Double(index) * height, width: 0.94, height: height)
            }
        }
    }
}

/// Everything needed to draw a meme on top of its template.
nonisolated struct MemeDocument: Codable, Hashable, Sendable {
    var templateID: String
    var boxes: [TextBox]
    /// A white strip above the image for a caption, as a fraction of the image height.
    var captionStrip = 0.0

    /// Every caption, for searching and for naming the meme.
    var caption: String {
        boxes.map(\.text).filter { !$0.isEmpty }.joined(separator: " / ")
    }

    var isEmpty: Bool {
        boxes.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Adds or removes the caption strip, keeping the boxes over the same part of the image.
    mutating func setCaptionStrip(_ on: Bool) {
        guard on != (captionStrip > 0) else { return }
        let strip = 0.28
        if on {
            let imageFraction = 1 / (1 + strip)
            for index in boxes.indices {
                boxes[index].y = 1 - imageFraction + boxes[index].y * imageFraction
                boxes[index].height *= imageFraction
            }
            captionStrip = strip
            var caption = TextBox(x: 0.03, y: 0.01, width: 0.94, height: (1 - imageFraction) - 0.02)
            caption.font = .helvetica
            caption.color = "#000000"
            caption.outline = "#FFFFFF"
            caption.allCaps = false
            caption.align = .left
            boxes.insert(caption, at: 0)
        } else {
            let imageFraction = 1 / (1 + captionStrip)
            boxes.removeAll { $0.y + $0.height <= 1 - imageFraction + 0.001 }
            for index in boxes.indices {
                boxes[index].y = (boxes[index].y - (1 - imageFraction)) / imageFraction
                boxes[index].height /= imageFraction
            }
            captionStrip = 0
        }
    }
}

/// A finished meme, saved as a PNG in the library.
nonisolated struct SavedMeme: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var document: MemeDocument
    var created = Date()

    var caption: String { document.caption }
    var title: String { caption.isEmpty ? name : caption }
}
