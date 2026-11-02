import AppKit
import Carbon.HIToolbox

/// The global shortcut. Carbon's hot keys need no Accessibility permission.
final class HotKey {
    static let shared = HotKey()

    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        /// NSEvent.ModifierFlags raw value.
        var modifiers: UInt
        /// What the key shows on the user's keyboard.
        var character: String

        static let standard = Combo(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue,
            character: "M"
        )

        var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

        var label: String {
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            return text + character
        }

        var carbonModifiers: UInt32 {
            var value: UInt32 = 0
            if flags.contains(.control) { value |= UInt32(controlKey) }
            if flags.contains(.option) { value |= UInt32(optionKey) }
            if flags.contains(.shift) { value |= UInt32(shiftKey) }
            if flags.contains(.command) { value |= UInt32(cmdKey) }
            return value
        }
    }

    var onPress: () -> Void = {}
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    private static let defaultsKey = "hotKey"

    var combo: Combo {
        get {
            UserDefaults.standard.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Combo.self, from: $0) } ?? .standard
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.defaultsKey)
            register()
        }
    }

    func start() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKey.shared.onPress() }
            return noErr
        }, 1, &type, nil, &handler)
        register()
    }

    private func register() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        let id = EventHotKeyID(signature: OSType(0x484D_454D), id: 1) // "HMEM"
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
    }
}
