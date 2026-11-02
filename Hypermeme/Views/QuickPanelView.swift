import SwiftUI

/// The state of the menu bar panel: browsing, or captioning one template.
@Observable
final class QuickPanelModel {
    var browse = BrowseModel()
    var editor: MemeEditor?
    var selectedIndex = 0
    /// Bumped each time the panel opens, to put the cursor in the search field.
    var openCount = 0

    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored var onOpenInWindow: (MemeEditor) -> Void = { _ in }

    static let columns = 3

    var itemCount: Int {
        browse.section == .memes ? browse.memes.count : browse.templates.count
    }

    func prepare(query: String?) {
        Task { await Library.shared.refresh() }
        Inserter.shared.refreshAccess()
        editor = nil
        selectedIndex = 0
        browse.query = query ?? ""
    }

    func open(_ template: MemeTemplate) {
        let editor = MemeEditor(template: template)
        self.editor = editor
        Task { await editor.load() }
    }

    func move(by delta: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), itemCount - 1)
    }

    /// Return in the grid: opens a template, or inserts a finished meme.
    func activateSelection() {
        if browse.section == .memes {
            guard browse.memes.indices.contains(selectedIndex) else { return }
            insert(browse.memes[selectedIndex])
        } else {
            guard browse.templates.indices.contains(selectedIndex) else { return }
            open(browse.templates[selectedIndex])
        }
    }

    func insert(_ meme: SavedMeme) {
        Library.shared.moveToTop(meme)
        let file = Library.shared.file(for: meme)
        onClose()
        Inserter.shared.insert(file, reactivate: false)
    }

    func insertEditor() {
        guard let file = editor?.finish() else { return }
        onClose()
        Inserter.shared.insert(file, reactivate: false)
    }

    func copyEditor() {
        guard let file = editor?.finish() else { return }
        Inserter.shared.copy(file)
        onClose()
        Toast.show("Copied")
    }

    func editAgain(_ meme: SavedMeme) {
        guard let editor = MemeEditor(meme: meme) else { return }
        self.editor = editor
        Task { await editor.load() }
    }
}

struct QuickPanelView: View {
    @Bindable var model: QuickPanelModel

    var body: some View {
        ZStack {
            if let editor = model.editor {
                QuickEditor(editor: editor, model: model)
                    .transition(.opacity)
            } else {
                QuickBrowser(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.editor == nil)
        .frame(width: PanelController.size.width, height: PanelController.size.height)
        .background(Color.canvas)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(Color.hairline, lineWidth: 1)
        }
    }
}

private struct QuickBrowser: View {
    @Bindable var model: QuickPanelModel
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: QuickPanelModel.columns)
    private let sections: [BrowseSection] = [.popular, .recent, .favorites, .memes]

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Picker("Section", selection: $model.browse.section) {
                ForEach(sections) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Hairline()
            grid
            Hairline()
            footer
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.openCount) { searchFocused = true }
        .onChange(of: model.browse.section) { model.selectedIndex = 0 }
        .onChange(of: model.browse.query) { model.selectedIndex = 0 }
        .onExitCommand { handleEscape() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.subdued)
            TextField(placeholder, text: $model.browse.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($searchFocused)
                .onSubmit { model.activateSelection() }
                .onKeyPress(.upArrow) { model.move(by: -QuickPanelModel.columns); return .handled }
                .onKeyPress(.downArrow) { model.move(by: QuickPanelModel.columns); return .handled }
                .onKeyPress(.leftArrow) {
                    guard model.browse.query.isEmpty else { return .ignored }
                    model.move(by: -1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard model.browse.query.isEmpty else { return .ignored }
                    model.move(by: 1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    let index = sections.firstIndex(of: model.browse.section) ?? 0
                    model.browse.section = sections[(index + 1) % sections.count]
                    return .handled
                }
            if model.browse.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var placeholder: String {
        model.browse.section == .memes ? "Search your memes" : "Search memes"
    }

    private func handleEscape() {
        if model.browse.query.isEmpty {
            model.onClose()
        } else {
            model.browse.query = ""
        }
    }

    @ViewBuilder private var grid: some View {
        let browse = model.browse
        if model.itemCount == 0 {
            emptyState
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        if browse.section == .memes {
                            ForEach(Array(browse.memes.enumerated()), id: \.element.id) { index, meme in
                                MemeCell(
                                    meme: meme,
                                    isSelected: index == model.selectedIndex,
                                    onEdit: { model.editAgain(meme) },
                                    onInsert: { model.insert(meme) }
                                )
                                .onTapGesture { model.insert(meme) }
                            }
                        } else {
                            ForEach(Array(browse.templates.enumerated()), id: \.element.id) { index, template in
                                TemplateCell(template: template, isSelected: index == model.selectedIndex)
                                    .onTapGesture { model.open(template) }
                                    .onAppear {
                                        if index >= browse.templates.count - 6 {
                                            Task { await browse.loadMore() }
                                        }
                                    }
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.selectedIndex) { _, index in
                    // The grid's ForEach identifies cells by item, so that's what to scroll to.
                    if browse.section == .memes {
                        if browse.memes.indices.contains(index) { scroller.scrollTo(browse.memes[index].id, anchor: nil) }
                    } else if browse.templates.indices.contains(index) {
                        scroller.scrollTo(browse.templates[index].id, anchor: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        let browse = model.browse
        if browse.searchFailed {
            EmptyHint(symbol: "wifi.exclamationmark", title: "Search Isn't Reachable", detail: "Hypermeme couldn't reach imgflip.")
        } else if !browse.query.isEmpty {
            if browse.isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyHint(symbol: "magnifyingglass", title: "No Matches", detail: "Try another name for the meme.")
            }
        } else {
            switch browse.section {
            case .memes:
                EmptyHint(symbol: "face.smiling", title: "No Memes Yet", detail: "Memes you make stay here, ready to insert again.")
            case .favorites:
                EmptyHint(symbol: "star", title: "No Favorites", detail: "Star a template to keep it here.")
            case .recent:
                EmptyHint(symbol: "clock", title: "Nothing Recent", detail: "Templates you use show up here.")
            default:
                if Library.shared.loadFailed {
                    EmptyHint(symbol: "wifi.exclamationmark", title: "Offline", detail: "Hypermeme couldn't reach imgflip.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Hint(key: "↩", label: model.browse.section == .memes ? "Insert" : "Caption")
            Hint(key: "⇥", label: "Switch section")
            Spacer()
            Text(HotKey.shared.combo.label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.subdued)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct QuickEditor: View {
    @Bindable var editor: MemeEditor
    let model: QuickPanelModel
    @FocusState private var focused: TextBox.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.editor = nil } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .help("Back to templates")
                Text(editor.template.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button { model.onOpenInWindow(editor) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .help("Open in the full editor, for fonts, colors and more text")
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            Hairline()
            MemeCanvas(editor: editor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            Hairline()
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(Array($editor.document.boxes.enumerated()), id: \.element.id) { index, $box in
                        TextField("Text \(index + 1)", text: $box.text, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1 ... 3)
                            .focused($focused, equals: box.id)
                            .onSubmit { model.insertEditor() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: min(CGFloat(editor.document.boxes.count) * 32 + 22, 136))
            Hairline()
            HStack(spacing: 8) {
                Hint(key: "⎋", label: "Back")
                Spacer()
                Button("Copy") { model.copyEditor() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy without pasting (⇧⌘C)")
                Button("Insert") { model.insertEditor() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Paste into the app you were using (↩)")
            }
            .disabled(editor.image == nil)
            .padding(.horizontal, 14)
            .frame(height: 44)
        }
        .onAppear { focused = editor.document.boxes.first?.id }
        .onChange(of: focused) { _, new in
            if let new { editor.selection = new }
        }
        .onChange(of: editor.selection) { _, new in
            if let new { focused = new }
        }
        .onExitCommand { model.editor = nil }
    }
}

private struct Hint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            Text(label)
                .font(.system(size: 11))
        }
        .foregroundStyle(Color.subdued)
    }
}
