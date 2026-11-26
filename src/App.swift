import AppKit
import SwiftUI
import Carbon.HIToolbox

@main
enum Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Klick auf das Symbol oder Tastenkürzel: Verlauf öffnen
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = ClipStore()
    private let popover = NSPopover()
    private let toast = CopyToast()
    private var hotKey: HotKey?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var flashWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            setIcon(flash: false)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: ClipPanel(store: store))

        store.onCopied = { [weak self] item in self?.copied(item) }
        store.onPick = { [weak self] item, paste in self?.pick(item, paste: paste) }
        store.onHotkeyChange = { [weak self] in self?.hotKey?.register(self?.store.hotkey ?? 0) }
        store.start()

        hotKey = HotKey { [weak self] in MainActor.assumeIsolated { self?.togglePanel() } }
        hotKey?.register(store.hotkey)
    }

    func applicationWillTerminate(_ notification: Notification) { store.saveNow() }

    // MARK: - Panel

    @objc private func statusClicked() { togglePanel() }

    private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }
        store.resetForOpen()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startKeyMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Pfeiltasten, Return, Escape & Co., während das Panel offen ist
    private func startKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.popover.isShown, !self.store.showSettings else { return e }
            let cmd = e.modifierFlags.contains(.command)
            let opt = e.modifierFlags.contains(.option)
            switch Int(e.keyCode) {
            case kVK_DownArrow: self.store.move(1); return nil
            case kVK_UpArrow: self.store.move(-1); return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let item = self.store.selectedItem { self.pick(item, paste: !opt) }
                return nil
            case kVK_Escape:
                if self.store.query.isEmpty { self.popover.performClose(nil) } else { self.store.query = "" }
                return nil
            case kVK_Delete where opt:
                if let item = self.store.selectedItem { self.store.delete(item) }
                return nil
            case kVK_ANSI_P where cmd:
                if let item = self.store.selectedItem { self.store.togglePin(item) }
                return nil
            case kVK_ANSI_Comma where cmd:
                self.store.showSettings = true
                return nil
            default: break
            }
            if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                let v = self.store.visible
                if v.indices.contains(n - 1) { self.pick(v[n - 1], paste: !opt) }
                return nil
            }
            return e
        }
    }

    // MARK: - Auswählen & Einfügen

    private func pick(_ item: ClipItem, paste: Bool) {
        store.copy(item)
        popover.performClose(nil)
        let target = previousApp
        previousApp = nil
        guard paste, store.autoPaste else { return }
        guard Paster.isTrusted else { Paster.requestTrust(); return }
        target?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Paster.pasteCommandV() }
    }

    // MARK: - Feedback beim Kopieren

    private func copied(_ item: ClipItem) {
        guard store.feedback != 2 else { return }
        if store.feedback == 0 { toast.show(item) }
        setIcon(flash: true)
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setIcon(flash: false) }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func setIcon(flash: Bool) {
        guard let button = statusItem.button else { return }
        let img = NSImage(systemSymbolName: flash ? "checkmark.circle.fill" : "list.clipboard",
                          accessibilityDescription: "ClipBar")
        img?.isTemplate = true
        button.image = img
        button.toolTip = "ClipBar – Verlauf der Zwischenablage"
    }
}
