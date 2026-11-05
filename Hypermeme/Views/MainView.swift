import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: MainModel
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                ForEach(BrowseSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .foregroundStyle(Color.primary)
                        .tag(section)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sidebar.ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            if let editor = model.editor {
                EditorView(editor: editor) { model.closeEditor() }
                    .id(ObjectIdentifier(editor))
            } else {
                BrowseGrid(model: model)
            }
        }
        .background(Color.canvas)
        .toolbarBackground(Color.canvas, for: .windowToolbar)
        .searchable(text: $model.browse.query, placement: .toolbar, prompt: "Search memes")
        .onChange(of: model.browse.query) { _, query in
            if !query.isEmpty { model.closeEditor() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let template = Library.shared.addUpload(file: url) else { return false }
            model.open(MemeEditor(template: template))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var selection: Binding<BrowseSection?> {
        Binding(
            get: { model.browse.section },
            set: { section in
                if let section {
                    model.browse.section = section
                    model.closeEditor()
                }
            }
        )
    }
}

private struct BrowseGrid: View {
    let model: MainModel

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16, alignment: .top)]

    var body: some View {
        let browse = model.browse
        Group {
            if browse.section == .memes ? browse.memes.isEmpty : browse.templates.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        if browse.section == .memes {
                            ForEach(browse.memes) { meme in
                                MemeCell(meme: meme, onEdit: { edit(meme) }, onInsert: { insert(meme) })
                                    .onTapGesture { edit(meme) }
                            }
                        } else {
                            ForEach(browse.templates) { template in
                                TemplateCell(
                                    template: template,
                                    onDelete: template.isUpload ? { Library.shared.delete(upload: template) } : nil
                                )
                                .onTapGesture { model.open(MemeEditor(template: template)) }
                                .onAppear {
                                    if template.id == browse.templates.last?.id {
                                        Task { await browse.loadMore() }
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(browse.section.title)
        .toolbar {
            if browse.section == .uploads {
                ToolbarItem {
                    Button("Add Image", systemImage: "plus") {
                        (NSApp.delegate as? AppDelegate)?.mainWindow.addImage()
                    }
                }
            }
        }
    }

    private func edit(_ meme: SavedMeme) {
        if let editor = MemeEditor(meme: meme) { model.open(editor) }
    }

    private func insert(_ meme: SavedMeme) {
        Inserter.shared.insert(Library.shared.file(for: meme), reactivate: true)
    }

    @ViewBuilder private var empty: some View {
        let browse = model.browse
        if browse.searchFailed {
            EmptyHint(symbol: "wifi.exclamationmark", title: "Search Isn't Reachable", detail: "Hypermeme couldn't reach imgflip.")
        } else if !browse.query.isEmpty {
            if browse.isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: browse.query)
            }
        } else {
            switch browse.section {
            case .memes: EmptyHint(symbol: "face.smiling", title: "No Memes Yet", detail: "Memes you make stay here, ready to insert again.")
            case .favorites: EmptyHint(symbol: "star", title: "No Favorites", detail: "Star a template to keep it here.")
            case .recent: EmptyHint(symbol: "clock", title: "Nothing Recent", detail: "Templates you use show up here.")
            case .uploads: EmptyHint(symbol: "photo.on.rectangle", title: "No Images", detail: "Drop an image here, or paste one with ⇧⌘V, to caption it.")
            case .popular:
                if Library.shared.loadFailed {
                    EmptyHint(symbol: "wifi.exclamationmark", title: "Offline", detail: "Hypermeme couldn't reach imgflip.")
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

private struct EditorView: View {
    @Bindable var editor: MemeEditor
    let close: () -> Void
    @FocusState private var focused: TextBox.ID?

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.canvas
                MemeCanvas(editor: editor).padding(28)
            }
            .contentShape(.rect)
            Color.hairline.frame(width: 1)
            inspector
                .frame(width: 340)
                .background(Color.canvas)
        }
        .navigationTitle(editor.template.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: close)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save As…", systemImage: "square.and.arrow.down", action: saveAs)
                    .disabled(editor.image == nil)
                Button("Copy", systemImage: "doc.on.doc", action: copy)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(editor.image == nil)
            }
        }
        .onAppear { focused = editor.document.boxes.first?.id }
        .onChange(of: editor.selection) { _, new in focused = new }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array($editor.document.boxes.enumerated()), id: \.element.id) { index, $box in
                        BoxInspector(
                            box: $box,
                            label: "Text \(index + 1)",
                            isSelected: editor.selection == box.id,
                            focus: $focused,
                            select: { editor.selection = box.id },
                            remove: { editor.remove(box.id) }
                        )
                    }
                    HStack {
                        Button("Add Text", systemImage: "plus") { editor.addBox() }
                        Spacer()
                        Toggle("Caption Strip", isOn: captionStrip)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("A white strip above the image for a caption")
                    }
                }
                .padding(16)
            }
            Hairline()
            HStack {
                Label("Drag Out", systemImage: "hand.draw")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subdued)
                    .help("Drag this into another app to drop the meme there")
                    .onDrag(dragItem)
                Spacer()
                if editor.isFinishing {
                    ProgressView().controlSize(.small)
                }
                Button("Insert in Last App") {
                    Task {
                        if let file = await editor.finish() { Inserter.shared.insert(file, reactivate: true) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor.image == nil || editor.isFinishing)
            }
            .padding(12)
        }
    }

    private var captionStrip: Binding<Bool> {
        Binding(
            get: { editor.document.captionStrip > 0 },
            set: { on in
                editor.document.setCaptionStrip(on)
                editor.selection = editor.document.boxes.first?.id
            }
        )
    }

    /// The meme is made when the drop lands, since a video takes a moment to write.
    private func dragItem() -> NSItemProvider {
        let provider = NSItemProvider()
        let type: UTType = editor.template.isVideo ? .mpeg4Movie : .png
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { [editor] completion in
            Task { @MainActor in
                let file = await editor.finish()
                completion(file, false, file == nil ? CocoaError(.fileWriteUnknown) : nil)
            }
            return nil
        }
        return provider
    }

    private func copy() {
        Task {
            guard let file = await editor.finish() else { return }
            Inserter.shared.copy(file)
            Toast.show("Copied")
        }
    }

    private func saveAs() {
        Task {
            guard let file = await editor.finish() else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [editor.template.isVideo ? .mpeg4Movie : .png]
            panel.nameFieldStringValue = "\(editor.template.name).\(file.pathExtension)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: file, to: url)
        }
    }
}

struct SettingsView: View {
    @AppStorage("pasteDirectly") private var pasteDirectly = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var combo = HotKey.shared.combo
    private let inserter = Inserter.shared

    var body: some View {
        Form {
            LabeledContent("Open the panel with") {
                ShortcutRecorder(combo: $combo)
            }
            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            Section {
                Toggle("Paste into the app I'm using", isOn: $pasteDirectly)
                if pasteDirectly, !inserter.canPaste {
                    LabeledContent("Pasting needs Accessibility access. Until then, Insert copies the meme.") {
                        Button("Allow…") {
                            inserter.requestAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Your memes and images") {
                    Button("Show in Finder") { NSWorkspace.shared.open(Library.folder) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click, then press the new shortcut.
private struct ShortcutRecorder: View {
    @Binding var combo: HotKey.Combo
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press a shortcut…" : combo.label) {
            isRecording ? stop() : start()
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
                if event.keyCode == 53 {
                    stop()
                } else if !flags.subtracting(.shift).isEmpty {
                    let new = HotKey.Combo(
                        keyCode: UInt32(event.keyCode),
                        modifiers: flags.rawValue,
                        character: (event.charactersIgnoringModifiers ?? "").uppercased()
                    )
                    HotKey.shared.combo = new
                    combo = new
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
