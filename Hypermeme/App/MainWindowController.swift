import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The full app window. Hypermeme gets a Dock icon only while this is open.
final class MainWindowController: NSObject, NSWindowDelegate {
    let model = MainModel()

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Hypermeme"
        window.backgroundColor = NSColor(Color.canvas)
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)
        window.contentViewController = NSHostingController(rootView: MainView(model: model))
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        window.setFrameAutosaveName("Main")
        window.delegate = self
        return window
    }()

    func show(query: String? = nil, editing editor: MemeEditor? = nil) {
        if let query { model.browse.query = query }
        if let editor { model.open(editor) }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        show()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let template = Library.shared.addUpload(file: url) { model.open(MemeEditor(template: template)) }
    }

    func addFromClipboard() {
        show()
        if let template = Library.shared.addUploadFromClipboard() { model.open(MemeEditor(template: template)) }
    }
}

@Observable
final class MainModel {
    var browse = BrowseModel()
    private(set) var editor: MemeEditor?

    func open(_ editor: MemeEditor) {
        self.editor = editor
        Task { await editor.load() }
    }

    func closeEditor() { editor = nil }
}

final class SettingsWindowController: NSObject {
    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = "Hypermeme Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    func show() {
        Inserter.shared.refreshAccess()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
