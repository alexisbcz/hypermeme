import AppKit
import SwiftUI

/// A panel that can take the keyboard without activating Hypermeme. The app you're writing in
/// stays frontmost, which is what lets a meme land in it with a plain ⌘V.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 430, height: 580)

    weak var statusButton: NSStatusBarButton?
    var onOpenInWindow: (MemeEditor) -> Void = { _ in }

    private let model = QuickPanelModel()
    private var clickMonitor: Any?
    private var hiddenAt = Date.distantPast

    private lazy var panel: KeyablePanel = {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: QuickPanelView(model: model))
        return panel
    }()

    override init() {
        super.init()
        model.onClose = { [weak self] in self?.hide() }
        model.onOpenInWindow = { [weak self] editor in
            self?.hide()
            self?.onOpenInWindow(editor)
        }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        if isVisible {
            hide()
        } else if Date().timeIntervalSince(hiddenAt) > 0.2 {
            // The click that closes the panel from outside also lands on the status item.
            show()
        }
    }

    func show(query: String? = nil) {
        model.prepare(query: query)
        panel.setFrameOrigin(origin())
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI drops focus requests made before the panel is key, and Hypermeme isn't the active app.
        Task {
            try? await Task.sleep(for: .milliseconds(30))
            model.openCount += 1
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func show(editing editor: MemeEditor) {
        show()
        model.editor = editor
        Task { await editor.load() }
    }

    func hide() {
        guard panel.isVisible else { return }
        hiddenAt = Date()
        panel.orderOut(nil)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func windowDidResignKey(_: Notification) { hide() }

    /// Right under the status item, kept on its screen.
    private func origin() -> NSPoint {
        let margin = 8.0
        let screen = statusButton?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        var x = screen.visibleFrame.maxX - Self.size.width - margin
        if let button = statusButton, let window = button.window {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            x = frame.midX - Self.size.width / 2
        }
        x = min(max(x, screen.visibleFrame.minX + margin), screen.visibleFrame.maxX - Self.size.width - margin)
        return NSPoint(x: x, y: screen.visibleFrame.maxY - Self.size.height - 6)
    }
}

/// A short message that doesn't take focus, for when the panel has just closed.
enum Toast {
    private static var window: NSPanel?
    private static var task: Task<Void, Never>?

    static func hide() {
        task?.cancel()
        window?.orderOut(nil)
    }

    static func show(_ message: String, duration: Duration = .seconds(2)) {
        let view = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.canvas, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.hairline))
                .fixedSize()
        )
        let size = view.fittingSize
        let panel = window ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        panel.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        window = panel
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { panel.orderOut(nil) }
        }
    }
}
