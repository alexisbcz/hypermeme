import AppKit
import ApplicationServices
import CoreGraphics

/// Puts a finished meme on the clipboard and into whichever app the user was in.
@Observable
final class Inserter {
    static let shared = Inserter()

    /// Whether Hypermeme may press ⌘V for you. Without it, memes go on the clipboard.
    private(set) var canPaste = Inserter.hasAccess()

    /// The last app in front that wasn't Hypermeme, for inserting from the main window.
    @ObservationIgnored private var previousApp: NSRunningApplication?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var askedForAccess = false
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var timeout: Task<Void, Never>?

    private static let clickTimeout = Duration.seconds(20)

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

    func refreshAccess() { canPaste = Self.hasAccess() }

    /// CGPreflightPostEventAccess can keep its first answer until relaunch; AXIsProcessTrusted sees a new grant.
    private static func hasAccess() -> Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    func requestAccess() {
        canPaste = CGRequestPostEventAccess()
    }

    /// The image for apps that take pixels, and the file for apps that only take files.
    /// A video can only go as a file, which chat apps attach on paste.
    func copy(_ file: URL) {
        if file.pathExtension == "mp4" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([file as NSURL])
            return
        }
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        item.setString(file.absoluteString, forType: .fileURL)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    /// Saves a copy of the meme in Downloads, without replacing anything already there.
    func download(_ file: URL, name: String) {
        do {
            let destination = Self.freeFile(for: name, in: .downloadsDirectory, extension: file.pathExtension)
            try FileManager.default.copyItem(at: file, to: destination)
            Toast.show("Saved to Downloads")
        } catch {
            Toast.show("Couldn't save to Downloads")
        }
    }

    /// "Name.png", or "Name 2.png" and so on when that's taken.
    nonisolated static func freeFile(for name: String, in folder: URL, extension ext: String = "png") -> URL {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "Meme" : cleaned
        var file = folder.appending(path: "\(base).\(ext)")
        var number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: "\(base) \(number).\(ext)")
            number += 1
        }
        return file
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
            Toast.show("Copied. Press ⌘V to paste.")
            promptForAccess()
            return
        }
        if reactivate {
            NSApp.hide(nil)
            previousApp?.activate()
        }
        stopWaiting()
        Task {
            try? await Task.sleep(for: .milliseconds(reactivate ? 250 : 80))
            if Self.canTakePaste(role: Self.focusedRole()) {
                Self.pressPaste()
            } else {
                waitForClick()
            }
        }
    }

    // MARK: Asking for access

    /// macOS only shows its own request once, so Hypermeme asks itself, once per launch.
    private func promptForAccess() {
        guard !askedForAccess else { return }
        askedForAccess = true
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let Hypermeme paste for you"
        alert.informativeText = """
            Your meme is on the clipboard, so ⌘V works now. To paste with Insert, turn on Hypermeme under Accessibility. \
            If it's already on, turn it off and on again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Always Just Copy")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            requestAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            watchForAccess()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(false, forKey: "pasteDirectly")
        default:
            break
        }
    }

    /// Confirms the switch took, so the next Insert isn't the test.
    private func watchForAccess() {
        Task {
            for _ in 0 ..< 120 {
                try? await Task.sleep(for: .seconds(1))
                refreshAccess()
                if canPaste {
                    Toast.show("Hypermeme can paste now")
                    return
                }
            }
        }
    }

    // MARK: Choosing where it goes

    /// Holds the meme until the user clicks something that can take it. Esc gives up, and it
    /// stays on the clipboard either way.
    private func waitForClick() {
        Toast.show("Click where the meme should go", duration: Self.clickTimeout)
        let clicks = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.clicked() }
        }
        let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Esc
            MainActor.assumeIsolated {
                self?.stopWaiting()
                Toast.show("Copied. Press ⌘V to paste.")
            }
        }
        monitors = [clicks, keys].compactMap(\.self)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.clickTimeout)
            guard !Task.isCancelled else { return }
            self?.stopWaiting()
            Toast.show("Copied. Press ⌘V to paste.")
        }
    }

    /// The click is the user's choice, so it isn't second-guessed: browsers often don't report the field.
    private func clicked() {
        Task {
            // The app moves its focus after the click lands.
            try? await Task.sleep(for: .milliseconds(120))
            guard !monitors.isEmpty else { return }
            stopWaiting()
            Toast.hide()
            Self.pressPaste()
        }
    }

    private func stopWaiting() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        timeout?.cancel()
        timeout = nil
    }

    /// False only for what is known not to take a paste. Many apps don't report their focus, and
    /// those keep getting a plain ⌘V. That includes browsers, which can report the page for a field in it.
    nonisolated static func canTakePaste(role: String?) -> Bool {
        guard let role else { return true }
        return !["AXWindow", "AXApplication", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXButton"].contains(role)
    }

    private static func focusedRole() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
        return role as? String
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
