import Foundation

/// An image to caption: one of imgflip's templates, or a picture of the user's own.
nonisolated struct MemeTemplate: Codable, Identifiable, Hashable, Sendable {
    /// imgflip's image key (such as "30b1gx"), or "upload-…" for the user's own.
    var id: String
    var name: String
    /// The name in imgflip's URLs, such as "Drake-Hotline-Bling".
    var slug: String?
    var fileType = "jpg"
    var boxCount = 2
    /// Other names people know the template by, comma separated.
    var altNames = ""
    /// imgflip's layout, once known.
    var boxes: [TextBox]?

    var isUpload: Bool { id.hasPrefix("upload-") }

    var imageURL: URL? {
        isUpload ? nil : URL(string: "https://i.imgflip.com/\(id).\(fileType)")
    }

    var thumbnailURL: URL? {
        isUpload ? nil : URL(string: "https://i.imgflip.com/4/\(id).jpg")
    }

    var startingBoxes: [TextBox] {
        let boxes = boxes ?? TextBox.defaults(count: boxCount)
        return boxes.isEmpty ? TextBox.defaults(count: 2) : boxes
    }

    /// Matches every word of a query against the name and the other names.
    /// Higher is better; nil means no match.
    func score(for query: String) -> Int? {
        let name = name.lowercased()
        let haystack = name + " " + altNames.lowercased()
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.allSatisfy(haystack.contains) else { return nil }
        if name == query.lowercased() { return 3 }
        if name.hasPrefix(words[0]) { return 2 }
        return words.allSatisfy(name.contains) ? 1 : 0
    }
}
