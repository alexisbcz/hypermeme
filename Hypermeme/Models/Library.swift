import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The templates, favorites and finished memes, kept in Application Support.
@Observable
final class Library {
    static let shared = Library()

    private(set) var popular: [MemeTemplate] = []
    private(set) var uploads: [MemeTemplate] = []
    private(set) var memes: [SavedMeme] = []
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []
    private(set) var loadFailed = false
    private(set) var canLoadMore = true

    @ObservationIgnored private var known: [String: MemeTemplate] = [:]
    @ObservationIgnored private var catalogDate = Date.distantPast
    /// Page 3 of imgflip's listing is where the API's 100 run out.
    @ObservationIgnored private var nextPage = 3
    @ObservationIgnored private var isLoadingMore = false

    private struct State: Codable {
        var popular: [MemeTemplate] = []
        var known: [String: MemeTemplate] = [:]
        var catalogDate = Date.distantPast
        var uploads: [MemeTemplate] = []
        var memes: [SavedMeme] = []
        var favorites: [String] = []
        var recents: [String] = []
    }

    nonisolated static let folder: URL = {
        let folder = URL.applicationSupportDirectory.appending(path: "Hypermeme", directoryHint: .isDirectory)
        for name in ["Templates", "Memes"] {
            try? FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        return folder
    }()

    private static var stateFile: URL { folder.appending(path: "library.json") }

    private init() {
        guard let data = try? Data(contentsOf: Self.stateFile),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        popular = state.popular
        known = state.known
        catalogDate = state.catalogDate
        uploads = state.uploads
        memes = state.memes
        favorites = state.favorites
        recents = state.recents
    }

    private func save() {
        let state = State(
            popular: popular, known: known, catalogDate: catalogDate,
            uploads: uploads, memes: memes, favorites: favorites, recents: recents
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateFile, options: .atomic)
        }
    }

    // MARK: Catalog

    /// Fetches the popular templates, at most once a day. The cached list shows meanwhile.
    func refresh() async {
        guard popular.isEmpty || Date().timeIntervalSince(catalogDate) > 86_400 else { return }
        do {
            let list = try await Imgflip.popular()
            popular = list.map { merged($0) }
            for template in popular where known[template.id] == nil { known[template.id] = template }
            catalogDate = Date()
            loadFailed = false
            // Any generator page carries the layouts and other names of the top templates.
            if let details = try? await Imgflip.details(slug: "Drake-Hotline-Bling") { remember(details) }
            save()
        } catch {
            loadFailed = popular.isEmpty
        }
    }

    func loadMore() async {
        guard canLoadMore, !isLoadingMore, !popular.isEmpty else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await Imgflip.templates(page: nextPage) else { return }
        nextPage += 1
        let seen = Set(popular.map(\.id))
        let fresh = page.filter { !seen.contains($0.id) }.map { merged($0) }
        popular.append(contentsOf: fresh)
        canLoadMore = !page.isEmpty
    }

    /// Fills in what's already known about a template from a thinner listing.
    func merged(_ template: MemeTemplate) -> MemeTemplate {
        guard let known = known[template.id] else { return template }
        var result = template
        result.slug = template.slug ?? known.slug
        result.boxes = known.boxes
        result.altNames = known.altNames
        if known.boxes != nil { result.boxCount = known.boxCount }
        return result
    }

    private func remember(_ details: [MemeTemplate]) {
        for template in details { known[template.id] = template }
        popular = popular.map { merged($0) }
    }

    func template(id: String) -> MemeTemplate? {
        uploads.first { $0.id == id } ?? known[id] ?? popular.first { $0.id == id }
    }

    var favoriteTemplates: [MemeTemplate] { favorites.compactMap(template(id:)) }
    var recentTemplates: [MemeTemplate] { recents.compactMap(template(id:)) }

    /// Every template Hypermeme has seen that matches, best first.
    func localMatches(_ query: String) -> [MemeTemplate] {
        let all = uploads + popular + known.values.filter { known in !popular.contains { $0.id == known.id } }
        return all.compactMap { template in template.score(for: query).map { (template, $0) } }
            .enumerated()
            .sorted { ($0.element.1, $1.offset) > ($1.element.1, $0.offset) }
            .map(\.element.0)
    }

    func remember(results: [MemeTemplate]) -> [MemeTemplate] {
        let merged = results.map { merged($0) }
        for template in merged where known[template.id] == nil { known[template.id] = template }
        return merged
    }

    /// Looks up imgflip's layout for a template, if it isn't known yet.
    func resolved(_ template: MemeTemplate) async -> MemeTemplate {
        guard !template.isUpload, template.boxes == nil else { return template }
        let slug = template.slug ?? template.name.replacingOccurrences(of: " ", with: "-")
        guard let details = try? await Imgflip.details(slug: slug) else { return template }
        remember(details)
        guard let found = details.first(where: { $0.id == template.id }) else { return template }
        save()
        return found
    }

    func templateFile(_ template: MemeTemplate) -> URL {
        Self.folder.appending(path: "Templates/\(template.id).\(template.isUpload ? "png" : template.fileType)")
    }

    func image(for template: MemeTemplate) async throws -> CGImage {
        let file = templateFile(template)
        if !FileManager.default.fileExists(atPath: file.path), let url = template.imageURL {
            let (data, response) = try await Imgflip.session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Imgflip.Failure.badResponse }
            try data.write(to: file, options: .atomic)
        }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Imgflip.Failure.badResponse }
        return image
    }

    // MARK: Favorites and recents

    func isFavorite(_ template: MemeTemplate) -> Bool { favorites.contains(template.id) }

    func toggleFavorite(_ template: MemeTemplate) {
        known[template.id] = known[template.id] ?? template
        if let index = favorites.firstIndex(of: template.id) {
            favorites.remove(at: index)
        } else {
            favorites.insert(template.id, at: 0)
        }
        save()
    }

    func noteUsed(_ template: MemeTemplate) {
        known[template.id] = known[template.id] ?? template
        recents.removeAll { $0 == template.id }
        recents.insert(template.id, at: 0)
        recents = Array(recents.prefix(60))
        save()
    }

    // MARK: Your images

    /// Makes a template of an image file or clipboard data. EXIF rotation is applied, and huge photos scaled down.
    func addUpload(_ source: CGImageSource, name: String) -> MemeTemplate? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = MemeRenderer.png(image) else { return nil }
        let template = MemeTemplate(id: "upload-\(UUID().uuidString.lowercased())", name: name, fileType: "png")
        do { try png.write(to: templateFile(template), options: .atomic) } catch { return nil }
        uploads.insert(template, at: 0)
        save()
        return template
    }

    func addUpload(file: URL) -> MemeTemplate? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return addUpload(source, name: file.deletingPathExtension().lastPathComponent)
    }

    func addUploadFromClipboard() -> MemeTemplate? {
        let pasteboard = NSPasteboard.general
        if let file = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]])?.first as? URL {
            return addUpload(file: file)
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return addUpload(source, name: "Pasted Image")
    }

    func delete(upload template: MemeTemplate) {
        uploads.removeAll { $0.id == template.id }
        favorites.removeAll { $0 == template.id }
        recents.removeAll { $0 == template.id }
        try? FileManager.default.removeItem(at: templateFile(template))
        save()
    }

    // MARK: Finished memes

    func file(for meme: SavedMeme) -> URL {
        Self.folder.appending(path: "Memes/\(meme.id.uuidString).png")
    }

    /// Writes the full-size PNG. Saving the same meme twice gives back the first copy.
    func save(_ document: MemeDocument, on image: CGImage, template: MemeTemplate) -> SavedMeme? {
        noteUsed(template)
        if let existing = memes.first(where: { $0.document == document }),
           FileManager.default.fileExists(atPath: file(for: existing).path) {
            return existing
        }
        guard let rendered = MemeRenderer.render(image, document: document),
              let png = MemeRenderer.png(rendered) else { return nil }
        let meme = SavedMeme(name: template.name, document: document)
        do { try png.write(to: file(for: meme), options: .atomic) } catch { return nil }
        memes.insert(meme, at: 0)
        save()
        return meme
    }

    func delete(_ meme: SavedMeme) {
        memes.removeAll { $0.id == meme.id }
        try? FileManager.default.removeItem(at: file(for: meme))
        save()
    }

    func moveToTop(_ meme: SavedMeme) {
        guard let index = memes.firstIndex(of: meme) else { return }
        memes.move(fromOffsets: [index], toOffset: 0)
        save()
    }
}
