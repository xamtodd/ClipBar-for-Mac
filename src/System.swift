import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// Globales Tastenkürzel über Carbon (braucht keine Bedienungshilfen-Freigabe)
final class HotKey {
    static let options: [(label: String, key: UInt32, mods: UInt32)] = [
        ("⇧⌘C", UInt32(kVK_ANSI_C), UInt32(cmdKey | shiftKey)),
        ("⇧⌘V", UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey)),
        ("⌥⌘V", UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey)),
        ("⌃⌘V", UInt32(kVK_ANSI_V), UInt32(cmdKey | controlKey)),
    ]

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<HotKey>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ index: Int) {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let o = Self.options[Self.options.indices.contains(index) ? index : 0]
        let id = EventHotKeyID(signature: OSType(0x434C4250), id: 1) // "CLBP"
        RegisterEventHotKey(o.key, o.mods, id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Einfügen per simuliertem ⌘V in die vorherige App
enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func pasteCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

/// Kleiner, lautloser „Kopiert“-Hinweis neben dem Mauszeiger
@MainActor
final class CopyToast {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ item: ClipItem) {
        let label = ToastView.host(Self.subtitle(item))
        let size = label.fittingSize
        let mouse = NSEvent.mouseLocation
        var frame = NSRect(x: mouse.x + 14, y: mouse.y - size.height - 12, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let v = screen.visibleFrame
            frame.origin.x = min(frame.origin.x, v.maxX - size.width - 6)
            frame.origin.y = max(frame.origin.y, v.minY + 6)
        }

        let p = panel ?? {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            return p
        }()
        panel = p
        p.contentView = label
        p.setFrame(frame, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak p] in
            guard let p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    static func subtitle(_ item: ClipItem) -> String {
        switch item.kind {
        case .image: return "Bild kopiert"
        case .files:
            let n = item.text.split(separator: "\n").count
            return n == 1 ? "Datei kopiert" : "\(n) Dateien kopiert"
        case .text:
            let n = item.text.count
            return n == 1 ? "1 Zeichen kopiert" : "\(n.formatted()) Zeichen kopiert"
        }
    }
}
