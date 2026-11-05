import AppKit
import SwiftUI

/// Loads thumbnails through the cached session, keeping decoded images for quick scrolling.
enum ThumbnailCache {
    private static let images: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 600
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? { images.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await Imgflip.session.data(from: url).0
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.raised)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = ThumbnailCache.cached(url) {
                image = cached
                return
            }
            image = nil
            let loaded = await ThumbnailCache.load(url)
            withAnimation(.easeOut(duration: 0.15)) { image = loaded }
        }
    }
}

extension MemeTemplate {
    var gridImageURL: URL? {
        isUpload ? Library.shared.templateFile(self) : thumbnailURL
    }
}

/// Marks a video on its poster, with its length when known.
struct VideoBadge: View {
    var duration: Double?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
            if let duration {
                Text(Duration.seconds(duration.rounded()).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(5)
    }
}

extension MemeTemplate {
    /// Where to play a video from: the downloaded copy when there is one, otherwise the web.
    var playableURL: URL? {
        guard let videoURL else { return nil }
        let file = Library.folder.appending(path: "Templates/\(id).mp4")
        return FileManager.default.fileExists(atPath: file.path) ? file : videoURL
    }
}

struct TemplateCell: View {
    let template: MemeTemplate
    var isSelected = false
    var onDelete: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        let library = Library.shared
        VStack(spacing: 5) {
            Thumbnail(url: template.gridImageURL)
                .overlay {
                    // A video previews, muted, while the pointer is on it.
                    if isHovered, let url = template.playableURL {
                        LoopingVideo(url: url).allowsHitTesting(false)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : Color.hairline, lineWidth: isSelected ? 2.5 : 1)
                }
                .onDisappear { isHovered = false }
                .overlay(alignment: .topTrailing) {
                    if isHovered || library.isFavorite(template) {
                        Button {
                            library.toggleFavorite(template)
                        } label: {
                            Image(systemName: library.isFavorite(template) ? "star.fill" : "star")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(library.isFavorite(template) ? .yellow : .white)
                                .padding(5)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .help(library.isFavorite(template) ? "Remove from Favorites" : "Add to Favorites")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if template.isVideo { VideoBadge(duration: template.duration) }
                }
            Text(template.name)
                .font(.system(size: 11))
                .foregroundStyle(Color.subdued)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(library.isFavorite(template) ? "Remove from Favorites" : "Add to Favorites") {
                library.toggleFavorite(template)
            }
            if let onDelete {
                Divider()
                Button("Delete Image", role: .destructive, action: onDelete)
            }
        }
    }
}

struct MemeCell: View {
    let meme: SavedMeme
    var isSelected = false
    var onEdit: (() -> Void)?
    var onInsert: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        let library = Library.shared
        let file = library.file(for: meme)
        VStack(spacing: 5) {
            Thumbnail(url: library.thumbnail(for: meme))
                .overlay {
                    if isHovered, meme.isVideo == true {
                        LoopingVideo(url: file).allowsHitTesting(false)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(isSelected ? Color.accentColor : Color.hairline, lineWidth: isSelected ? 2.5 : 1)
                }
                .overlay(alignment: .bottomLeading) {
                    if meme.isVideo == true { VideoBadge() }
                }
            Text(meme.title)
                .font(.system(size: 11))
                .foregroundStyle(Color.subdued)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .draggable(file)
        .contextMenu {
            if let onInsert { Button("Insert", action: onInsert) }
            if meme.isVideo == true {
                Button("Play") { NSWorkspace.shared.open(file) }
            }
            Button("Copy") { Inserter.shared.copy(file) }
            Button("Download") { Inserter.shared.download(file, name: meme.name) }
            if let onEdit { Button("Edit Again", action: onEdit) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            Divider()
            Button("Delete", role: .destructive) { library.delete(meme) }
        }
    }
}

/// All, images or videos, as three small icons.
struct MediaFilterPicker: View {
    @Binding var filter: MediaFilter

    var body: some View {
        Picker("Show", selection: $filter) {
            ForEach(MediaFilter.allCases) { filter in
                Image(systemName: filter.symbol)
                    .help(filter.title)
                    .accessibilityLabel(filter.title)
                    .tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Show all memes, only images, or only videos")
    }
}

struct EmptyHint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
