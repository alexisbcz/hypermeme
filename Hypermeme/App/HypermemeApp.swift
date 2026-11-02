import AppKit
import SwiftUI

@main
struct HypermemeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Hypermeme's windows are AppKit's, so the status item can open them. This scene provides the menus.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { delegate.showSettings() }
                        .keyboardShortcut(",")
                    Button("Check for Updates…") { Updater.shared.check() }
                }
                CommandGroup(replacing: .newItem) {
                    Button("Add Image…") { delegate.mainWindow.addImage() }
                        .keyboardShortcut("o")
                    Button("New Meme from Clipboard") { delegate.mainWindow.addFromClipboard() }
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mainWindow = MainWindowController()
    private let panel = PanelController()
    private let settings = SettingsWindowController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_: Notification) {
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        installStatusItem()
        panel.statusButton = statusItem?.button
        panel.onOpenInWindow = { [mainWindow] editor in mainWindow.show(editing: editor) }
        HotKey.shared.onPress = { [panel] in panel.toggle() }
        HotKey.shared.start()
        _ = Updater.shared
        _ = Inserter.shared
        Task { await Library.shared.refresh() }
        if !launchedAtLogin, !CommandLine.arguments.contains("--background") {
            mainWindow.show()
        }
    }

    /// Opening the app from Finder while it's running brings up its window.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    /// hypermeme://panel?q=…, hypermeme://window, hypermeme://search?q=…,
    /// hypermeme://edit?template=drake&text=first&text=second, with &panel=1 to use the quick panel.
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value }
            switch url.host() {
            case "panel": panel.show(query: value("q"))
            case "search": mainWindow.show(query: value("q"))
            case "edit":
                let id = value("template") ?? ""
                guard let template = Library.shared.template(id: id) ?? Library.shared.localMatches(id).first else { continue }
                let editor = MemeEditor(template: template)
                editor.prefilledText = items.filter { $0.name == "text" }.compactMap(\.value)
                if value("panel") == nil {
                    mainWindow.show(editing: editor)
                } else {
                    panel.show(editing: editor)
                }
            case "settings": showSettings()
            default: mainWindow.show()
            }
        }
    }

    func showSettings() { settings.show() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.image
        item.button?.toolTip = "Hypermeme"
        item.button?.target = self
        item.button?.action = #selector(statusItemPressed)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
    }

    @objc private func statusItemPressed() {
        guard NSApp.currentEvent?.type == .rightMouseDown || NSApp.currentEvent?.modifierFlags.contains(.control) == true else {
            panel.toggle()
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Hypermeme", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Hypermeme", action: #selector(NSApplication.terminate), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openWindow() { mainWindow.show() }
    @objc private func openSettings() { showSettings() }
    @objc private func checkForUpdates() { Updater.shared.check() }
}

/// The app icon's grin, as a menu bar template image.
enum StatusIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 4.6, y: 2.6, width: 2.8, height: 5.4), xRadius: 1.4, yRadius: 1.4).fill()
            NSBezierPath(roundedRect: NSRect(x: 10.6, y: 2.6, width: 2.8, height: 5.4), xRadius: 1.4, yRadius: 1.4).fill()
            let mouth = NSBezierPath()
            mouth.move(to: NSPoint(x: 2.6, y: 10.4))
            mouth.curve(to: NSPoint(x: 9, y: 16), controlPoint1: NSPoint(x: 2.6, y: 13.6), controlPoint2: NSPoint(x: 5.4, y: 16))
            mouth.curve(to: NSPoint(x: 15.4, y: 10.4), controlPoint1: NSPoint(x: 12.6, y: 16), controlPoint2: NSPoint(x: 15.4, y: 13.6))
            mouth.line(to: NSPoint(x: 2.6, y: 9.4))
            mouth.close()
            let top = NSBezierPath(roundedRect: NSRect(x: 2.6, y: 9.4, width: 12.8, height: 2), xRadius: 0.9, yRadius: 0.9)
            mouth.fill()
            top.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hypermeme"
        return image
    }()
}
