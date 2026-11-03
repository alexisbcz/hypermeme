import Foundation

/// Templates imgflip doesn't have yet, from github.com/alexisbcz/hypermeme-templates.
///
/// Its index.json describes each one: other names, what's in the picture, what it means and
/// tags, all of which search reads, so "coffee riot" finds a template named something else.
nonisolated enum Community {
    static let index = URL(string: "https://raw.githubusercontent.com/alexisbcz/hypermeme-templates/main/index.json")!

    static func templates() async throws -> [MemeTemplate] {
        let (data, response) = try await Imgflip.session.data(from: index)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Imgflip.Failure.badResponse }
        return try parse(data)
    }

    private struct Index: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let aliases: [String]
            let description: String
            let usage: String
            let tags: [String]
            let imageURL: URL
            let captionStrip: Bool
            let boxes: [Box]
        }
        /// Like `TextBox`, without the id and text.
        struct Box: Decodable {
            let x, y, width, height: Double
            var rotation: Double?
            var font: MemeFont?
            var color, outline: String?
            var allCaps: Bool?
            var align: HorizontalAlign?
            var verticalAlign: VerticalAlign?
            var shadow: Bool?
            var maxFontSize: Double?
        }
        let templates: [Entry]
    }

    static func parse(_ data: Data) throws -> [MemeTemplate] {
        try JSONDecoder().decode(Index.self, from: data).templates.map { entry in
            let boxes = entry.boxes.map { raw in
                var box = TextBox(x: raw.x, y: raw.y, width: raw.width, height: raw.height)
                box.rotation = raw.rotation ?? box.rotation
                box.font = raw.font ?? box.font
                box.color = raw.color ?? box.color
                box.outline = raw.outline ?? box.outline
                box.allCaps = raw.allCaps ?? box.allCaps
                box.align = raw.align ?? box.align
                box.verticalAlign = raw.verticalAlign ?? box.verticalAlign
                box.shadow = raw.shadow ?? box.shadow
                box.maxFontSize = raw.maxFontSize
                return box
            }
            return MemeTemplate(
                id: MemeTemplate.communityPrefix + entry.id,
                name: entry.name,
                fileType: entry.imageURL.pathExtension.isEmpty ? "jpg" : entry.imageURL.pathExtension,
                boxCount: boxes.count,
                altNames: (entry.aliases + entry.tags + [entry.description, entry.usage]).joined(separator: ", "),
                boxes: boxes,
                sourceImageURL: entry.imageURL,
                captionStrip: entry.captionStrip
            )
        }
    }
}
