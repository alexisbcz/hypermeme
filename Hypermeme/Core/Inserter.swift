import AppKit
import CoreGraphics

/// Puts a finished meme on the clipboard and into whichever app the user was in.
@Observable
final class Inserter {
    static let shared = Inserter()

    /// Whether Hypermeme may press ⌘V for you. Without it, memes go on the clipboard.
    private(set) var canPaste = CGPreflightPostEventAccess()

    /// The last app in front that wasn't Hypermeme, for inserting from the main window.
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app != .current { self?.previousApp = app }
            }
        }
    }

    func refreshAccess() { canPaste = CGPreflightPostEventAccess() }

    func requestAccess() {
        canPaste = CGRequestPostEventAccess()
    }

    /// The image for apps that take pixels, and the file for apps that only take files.
    func copy(_ file: URL) {
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        item.setString(file.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Copies the meme and pastes it. The quick panel never takes focus from the app the user is in,
    /// so `reactivate` is only needed from the main window.
    func insert(_ file: URL, reactivate: Bool) {
        copy(file)
        refreshAccess()
        guard UserDefaults.standard.object(forKey: "pasteDirectly") as? Bool ?? true else {
            Toast.show("Copied")
            return
        }
        guard canPaste else {
            requestAccess()
            Toast.show("Copied. Press ⌘V to paste.")
            return
        }
        if reactivate {
            NSApp.hide(nil)
            previousApp?.activate()
        }
        Task {
            try? await Task.sleep(for: .milliseconds(reactivate ? 250 : 80))
            Self.pressPaste()
        }
    }

    private static func pressPaste() {
        let keyV: CGKeyCode = 9
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }
}
