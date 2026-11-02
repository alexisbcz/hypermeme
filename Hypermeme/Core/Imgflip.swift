import Foundation

/// imgflip's public template catalog.
///
/// Its API lists only the 100 most popular templates and hides search behind a paid plan, so
/// browsing further and searching read the public pages. The generator pages also embed each
/// template's text layout, which is what makes a Drake caption land next to Drake.
nonisolated enum Imgflip {
    enum Failure: LocalizedError {
        case badResponse
        var errorDescription: String? { "imgflip sent back something unexpected." }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "Hypermeme (+https://github.com/alexisbcz/hypermeme)"]
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    private static func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.badResponse }
        return data
    }

    // MARK: Requests

    static func popular() async throws -> [MemeTemplate] {
        try parseAPI(await fetch(URL(string: "https://api.imgflip.com/get_memes")!))
    }

    /// Later pages of the most popular templates. Page 1 is the same list as `popular()`.
    static func templates(page: Int) async throws -> [MemeTemplate] {
        var url = URLComponents(string: "https://imgflip.com/memetemplates")!
        url.queryItems = [URLQueryItem(name: "page", value: String(page))]
        return parseListing(String(decoding: try await fetch(url.url!), as: UTF8.self))
    }

    static func search(_ query: String, page: Int = 1) async throws -> [MemeTemplate] {
        var url = URLComponents(string: "https://imgflip.com/memesearch")!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "page", value: String(page))]
        return parseListing(String(decoding: try await fetch(url.url!), as: UTF8.self))
    }

    /// One generator page lists the popular templates and the one it's for, with their layouts.
    static func details(slug: String) async throws -> [MemeTemplate] {
        let url = URL(string: "https://imgflip.com/memegenerator/")!.appendingPathComponent(slug)
        return parseGenerator(String(decoding: try await fetch(url), as: UTF8.self))
    }

    // MARK: Parsing

    private struct APIResponse: Decodable {
        struct Page: Decodable {
            struct Meme: Decodable { let name: String; let url: URL; let box_count: Int }
            let memes: [Meme]
        }
        let data: Page
    }

    static func parseAPI(_ data: Data) throws -> [MemeTemplate] {
        try JSONDecoder().decode(APIResponse.self, from: data).data.memes.map { meme in
            MemeTemplate(
                id: meme.url.deletingPathExtension().lastPathComponent,
                name: meme.name,
                fileType: meme.url.pathExtension,
                boxCount: meme.box_count
            )
        }
    }

    /// Reads the cards of a /memetemplates or /memesearch page, leaving out animated templates.
    static func parseListing(_ html: String) -> [MemeTemplate] {
        html.components(separatedBy: "class=\"mt-box\"").dropFirst().compactMap { card in
            guard card.contains("href=\"/memegenerator/"),
                  let slug = firstMatch(of: /href="\/memegenerator\/([^"?]+)"/, in: card),
                  let key = firstMatch(of: /i\.imgflip\.com\/\d\/([a-z0-9]+)\.[a-z]+/, in: card),
                  let name = firstMatch(of: /<h3 class="mt-title">\s*<a[^>]*>([^<]+)<\/a>/, in: card)
            else { return nil }
            return MemeTemplate(id: key, name: decodeEntities(name), slug: slug)
        }
    }

    /// Reads the `memes=` data of a generator page: an array, or an object when the page is for a
    /// template outside the popular ones.
    static func parseGenerator(_ html: String) -> [MemeTemplate] {
        guard let start = html.range(of: "memes=")?.upperBound,
              let json = balancedJSON(in: html[start...]),
              let value = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return [] }
        let entries: [[String: Any]]
        if let list = value as? [[String: Any]] {
            entries = list
        } else if let map = value as? [String: [String: Any]] {
            entries = Array(map.values)
        } else {
            return []
        }
        return entries.compactMap(template(from:))
    }

    private static func template(from entry: [String: Any]) -> MemeTemplate? {
        guard let id = entry["id"] as? Int, let name = entry["name"] as? String else { return nil }
        var template = MemeTemplate(
            id: String(id, radix: 36),
            name: name,
            slug: entry["url_name"] as? String,
            fileType: entry["file_type"] as? String ?? "jpg",
            altNames: entry["altNames"] as? String ?? ""
        )
        if let settings = entry["default_settings"] as? String,
           let width = number(entry["w"]), let height = number(entry["h"]), width > 0, height > 0,
           let raw = try? JSONSerialization.jsonObject(with: Data(settings.utf8)) as? [[String: Any]] {
            let boxes = raw.compactMap { box(from: $0, width: width, height: height) }
            if !boxes.isEmpty {
                template.boxes = boxes
                template.boxCount = boxes.count
            }
        }
        return template
    }

    private static func box(from raw: [String: Any], width: Double, height: Double) -> TextBox? {
        guard raw["type"] as? String ?? "text" == "text",
              let x = number(raw["x"]), let y = number(raw["y"]),
              let w = number(raw["w"]), let h = number(raw["h"])
        else { return nil }
        var box = TextBox(x: x / width, y: y / height, width: w / width, height: h / height)
        box.rotation = number(raw["rotation"]) ?? 0
        box.font = MemeFont(imgflip: raw["font"] as? String)
        box.color = (raw["font_color"] as? String)?.uppercased() ?? box.color
        box.outline = (raw["outline_color"] as? String)?.uppercased() ?? box.outline
        box.allCaps = raw["force_caps"] as? Bool ?? true
        box.align = (raw["text_align"] as? String).flatMap(HorizontalAlign.init) ?? .center
        box.verticalAlign = (raw["vertical_align"] as? String).flatMap(VerticalAlign.init) ?? .middle
        box.shadow = raw["font_shadow"] as? Bool ?? false
        box.maxFontSize = number(raw["font_max_size"]).map { $0 / height }
        return box
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string)
        default: nil
        }
    }

    private static func firstMatch(of regex: some RegexComponent<(Substring, Substring)>, in text: String) -> String? {
        (try? regex.regex.firstMatch(in: text)).map { String($0.output.1) }
    }

    private static func decodeEntities(_ text: String) -> String {
        [("&amp;", "&"), ("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The JSON array or object at the start of `text`, up to its matching close.
    static func balancedJSON(in text: Substring) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, byte) in text.utf8.enumerated() {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return String(text.utf8.prefix(offset + 1)) }
            default:
                if depth == 0 { return nil }
            }
        }
        return nil
    }
}
