import AppKit
import Observation

/// One meme being captioned. The editor window and the quick panel both work on this.
@Observable
final class MemeEditor {
    private(set) var template: MemeTemplate
    private(set) var image: CGImage?
    private(set) var preview: CGImage?
    /// A video template's MP4, once downloaded, to play under the captions.
    private(set) var video: URL?
    /// For a video template: the captions alone, drawn over the playing video at the preview's size.
    private(set) var captions: CGImage?
    private(set) var failed = false
    /// True while a video meme is being written, which takes a moment.
    private(set) var isFinishing = false
    var selection: TextBox.ID?
    /// Text to place once the template's layout is known.
    @ObservationIgnored var prefilledText: [String] = []

    var document: MemeDocument {
        didSet { if document != oldValue { renderPreview() } }
    }

    @ObservationIgnored private var renderTask: Task<Void, Never>?

    /// Sharp on a Retina screen without slowing typing down.
    private nonisolated static let previewWidth = 1400.0

    init(template: MemeTemplate, document: MemeDocument? = nil) {
        self.template = template
        self.document = document ?? template.startingDocument
        selection = self.document.boxes.first?.id
    }

    convenience init?(meme: SavedMeme) {
        guard let template = Library.shared.template(id: meme.document.templateID) else { return nil }
        self.init(template: template, document: meme.document)
    }

    func load() async {
        failed = false
        let untouched = document.isEmpty && document.captionStrip == 0
        let resolved = await Library.shared.resolved(template)
        // A newer layout only replaces boxes nobody has typed in.
        if resolved.boxes != nil, template.boxes == nil, untouched, document.isEmpty {
            template = resolved
            document.boxes = resolved.startingBoxes
            selection = document.boxes.first?.id
        } else {
            template = resolved
        }
        for (index, text) in prefilledText.enumerated() where document.boxes.indices.contains(index) {
            document.boxes[index].text = text
        }
        prefilledText = []
        // A video is fetched while the captions are typed, so Insert doesn't wait for the download.
        if template.isVideo {
            let template = template
            Task { [weak self] in self?.video = try? await Library.shared.video(for: template) }
        }
        do {
            image = try await Library.shared.image(for: template)
            renderPreview()
        } catch {
            failed = true
        }
    }

    private func renderPreview() {
        guard let image else { return }
        let document = document
        let isVideo = template.isVideo
        renderTask?.cancel()
        renderTask = Task {
            let (rendered, captions) = await Task.detached(priority: .userInitiated) {
                let width = min(max(Double(image.width), 800), Self.previewWidth)
                let picture = CGSize(width: width, height: (Double(image.height) * width / Double(image.width)).rounded())
                return (
                    MemeRenderer.render(image, document: document, width: width),
                    isVideo ? MemeRenderer.captions(document, size: picture) : nil
                )
            }.value
            if !Task.isCancelled {
                preview = rendered
                self.captions = captions
            }
        }
    }

    func binding(for id: TextBox.ID) -> Int? { document.boxes.firstIndex { $0.id == id } }

    func addBox() {
        let box = TextBox(x: 0.2, y: 0.4, width: 0.6, height: 0.2)
        document.boxes.append(box)
        selection = box.id
    }

    func remove(_ id: TextBox.ID) {
        document.boxes.removeAll { $0.id == id }
        selection = document.boxes.first?.id
    }

    /// Saves the meme to the library and returns its PNG, or its MP4 for a video template.
    func finish() async -> URL? {
        guard let image, !isFinishing else { return nil }
        isFinishing = true
        defer { isFinishing = false }
        guard let meme = await Library.shared.save(document, on: image, template: template) else {
            Toast.show(template.isVideo ? "Couldn't make the video" : "Couldn't save the meme")
            return nil
        }
        return Library.shared.file(for: meme)
    }
}
