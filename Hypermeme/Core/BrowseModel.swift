import Observation

enum BrowseSection: String, CaseIterable, Identifiable {
    case popular, recent, favorites, uploads, memes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "Popular"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .uploads: "Your Images"
        case .memes: "My Memes"
        }
    }

    var symbol: String {
        switch self {
        case .popular: "flame"
        case .recent: "clock"
        case .favorites: "star"
        case .uploads: "photo.on.rectangle"
        case .memes: "face.smiling"
        }
    }
}

/// What a search field and a section show. Local matches appear at once; imgflip's follow.
@Observable
final class BrowseModel {
    var section = BrowseSection.popular { didSet { search() } }
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var remote: [MemeTemplate] = []
    private(set) var isSearching = false
    private(set) var searchFailed = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private var isLoadingPage = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var templates: [MemeTemplate] {
        let library = Library.shared
        let query = trimmedQuery
        switch section {
        case .popular:
            guard !query.isEmpty else { return library.popular }
            let local = library.localMatches(query)
            let seen = Set(local.map(\.id))
            return local + remote.filter { !seen.contains($0.id) }
        case .recent: return filtered(library.recentTemplates)
        case .favorites: return filtered(library.favoriteTemplates)
        case .uploads: return filtered(library.uploads)
        case .memes: return []
        }
    }

    /// A section's own matches, or imgflip's when it has none, so a search always reaches the catalog.
    private func filtered(_ templates: [MemeTemplate]) -> [MemeTemplate] {
        let query = trimmedQuery
        guard !query.isEmpty else { return templates }
        let matches = templates.filter { $0.score(for: query) != nil }
        return matches.isEmpty ? remote : matches
    }

    var memes: [SavedMeme] {
        let query = trimmedQuery.lowercased()
        let memes = Library.shared.memes
        guard !query.isEmpty else { return memes }
        let words = query.split(separator: " ").map(String.init)
        return memes.filter { meme in
            let haystack = (meme.caption + " " + meme.name).lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    private func search() {
        task?.cancel()
        remote = []
        page = 1
        hasMore = false
        searchFailed = false
        let query = trimmedQuery
        guard section != .memes, !query.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let results = try await Imgflip.search(query)
                guard !Task.isCancelled else { return }
                remote = Library.shared.remember(results: results)
                hasMore = !results.isEmpty
            } catch {
                guard !Task.isCancelled else { return }
                searchFailed = true
            }
            isSearching = false
        }
    }

    /// Called when the grid scrolls near its end.
    func loadMore() async {
        guard section != .memes else { return }
        guard !trimmedQuery.isEmpty else {
            if section == .popular { await Library.shared.loadMore() }
            return
        }
        guard hasMore, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }
        page += 1
        let query = trimmedQuery
        guard let results = try? await Imgflip.search(query, page: page), query == trimmedQuery else { return }
        let seen = Set(remote.map(\.id))
        remote += Library.shared.remember(results: results).filter { !seen.contains($0.id) }
        hasMore = !results.isEmpty
    }
}
