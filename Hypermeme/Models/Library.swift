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
    /// Changes when community templates arrive, so a search already on screen picks them up.
    private(set) var communityVersion = 0

    @ObservationIgnored private var known: [String: MemeTemplate] = [:]
    @ObservationIgnored private var catalogDate = Date.distantPast
    /// Page 3 of imgflip's listing is where the API's 100 run out.
    @ObservationIgnored private var nextPage = 3
    @ObservationIgnored private var isLoadingMore = false
    @ObservationIgnored private var communityDate = Date.distantPast

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
        await refreshCommunity()
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

    /// Fetches the templates imgflip doesn't have, at most once an hour. They're kept with the
    /// known templates, so search finds them, and favorites and recents keep them, offline too.
    func refreshCommunity() async {
        guard Date().timeIntervalSince(communityDate) > 3_600 else { return }
        guard let templates = try? await Community.templates() else { return }
        communityDate = Date()
        let ids = Set(templates.map(\.id))
        known = known.filter { !$0.key.hasPrefix(MemeTemplate.communityPrefix) || ids.contains($0.key) || isKept($0.key) }
        for template in templates { known[template.id] = template }
        communityVersion += 1
        save()
    }

    /// A template still in favorites or recents stays known after it leaves the community index.
    private func isKept(_ id: String) -> Bool { favorites.contains(id) || recents.contains(id) }

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

    /// Every video template, by name.
    var videoTemplates: [MemeTemplate] {
        _ = communityVersion
        return known.values.filter(\.isVideo).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var recentTemplates: [MemeTemplate] { recents.compactMap(template(id:)) }

    /// Every template Hypermeme has seen that matches, best first.
    func localMatches(_ query: String) -> [MemeTemplate] {
        _ = communityVersion
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
        guard !template.isUpload, template.sourceImageURL == nil, template.boxes == nil else { return template }
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

    /// A video template's MP4, downloaded the first time it's used.
    func video(for template: MemeTemplate) async throws -> URL {
        let file = Self.folder.appending(path: "Templates/\(template.id).mp4")
        if !FileManager.default.fileExists(atPath: file.path), let url = template.videoURL {
            let (data, response) = try await Imgflip.session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Imgflip.Failure.badResponse }
            try data.write(to: file, options: .atomic)
        }
        return file
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

    /// What gets inserted: the PNG, or a video meme's MP4.
    func file(for meme: SavedMeme) -> URL {
        Self.folder.appending(path: "Memes/\(meme.id.uuidString).\(meme.isVideo == true ? "mp4" : "png")")
    }

    /// The picture to show for a meme: the PNG itself, or a video meme's poster.
    func thumbnail(for meme: SavedMeme) -> URL {
        Self.folder.appending(path: "Memes/\(meme.id.uuidString).png")
    }

    /// Writes the full-size PNG, and for a video template the MP4 with the captions drawn in.
    /// Saving the same meme twice gives back the first copy.
    func save(_ document: MemeDocument, on image: CGImage, template: MemeTemplate) async -> SavedMeme? {
        noteUsed(template)
        if let existing = memes.first(where: { $0.document == document }),
           FileManager.default.fileExists(atPath: file(for: existing).path) {
            return existing
        }
        guard let rendered = MemeRenderer.render(image, document: document),
              let png = MemeRenderer.png(rendered) else { return nil }
        let meme = SavedMeme(name: template.name, document: document, isVideo: template.isVideo ? true : nil)
        do {
            try png.write(to: thumbnail(for: meme), options: .atomic)
            if template.isVideo {
                try await VideoExporter.export(video(for: template), document: document, to: file(for: meme))
            }
        } catch {
            try? FileManager.default.removeItem(at: thumbnail(for: meme))
            return nil
        }
        memes.insert(meme, at: 0)
        save()
        return meme
    }

    func delete(_ meme: SavedMeme) {
        memes.removeAll { $0.id == meme.id }
        try? FileManager.default.removeItem(at: file(for: meme))
        try? FileManager.default.removeItem(at: thumbnail(for: meme))
        save()
    }

    func moveToTop(_ meme: SavedMeme) {
        guard let index = memes.firstIndex(of: meme) else { return }
        memes.move(fromOffsets: [index], toOffset: 0)
        save()
    }
}
