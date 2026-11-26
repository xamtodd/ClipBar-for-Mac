import AppKit
import ServiceManagement

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, files }
    var id = UUID()
    var kind: Kind
    /// Text bzw. Dateipfade (durch Zeilenumbruch getrennt)
    var text: String
    /// Dateiname des Bildes im images-Ordner
    var image: String?
    var imageSize: CGSize?
    var date = Date()
    /// Bundle-ID der App, aus der kopiert wurde
    var app: String?
    var pinned = false
}

/// Verlauf, Einstellungen und das Beobachten der Zwischenablage
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = []
    @Published var query = "" { didSet { selected = 0 } }
    @Published var selected = 0
    @Published var showSettings = false
    /// Zählt bei jedem Öffnen hoch (setzt den Fokus ins Suchfeld)
    @Published private(set) var openCount = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var pasteAllowed = Paster.isTrusted

    // Einstellungen
    @Published var maxItems: Int = UserDefaults.standard.object(forKey: "maxItems") as? Int ?? 200 {
        didSet { UserDefaults.standard.set(maxItems, forKey: "maxItems"); trim(); save() }
    }
    @Published var hotkey: Int = UserDefaults.standard.integer(forKey: "hotkey") {
        didSet { UserDefaults.standard.set(hotkey, forKey: "hotkey"); onHotkeyChange?() }
    }
    /// 0 = Hinweis am Mauszeiger + Symbol, 1 = nur Symbol in der Menüleiste, 2 = aus
    @Published var feedback: Int = UserDefaults.standard.integer(forKey: "feedback") {
        didSet { UserDefaults.standard.set(feedback, forKey: "feedback") }
    }
    @Published var autoPaste: Bool = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoPaste, forKey: "autoPaste")
            if autoPaste && !Paster.isTrusted { Paster.requestTrust() }
        }
    }

    static let sizes = [50, 100, 200, 500, 1000]

    var onCopied: ((ClipItem) -> Void)?
    var onHotkeyChange: (() -> Void)?
    var onPick: ((ClipItem, _ paste: Bool) -> Void)?

    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private var thumbs: [String: NSImage] = [:]

    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: d.appendingPathComponent("images"),
                                                 withIntermediateDirectories: true)
        return d
    }()
    private var historyURL: URL { dir.appendingPathComponent("history.json") }
    private func imageURL(_ name: String) -> URL { dir.appendingPathComponent("images").appendingPathComponent(name) }

    // MARK: - Start

    func start() {
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Nur für Screenshots: Verlauf vorgeben, ohne zu speichern
    func setDemo(_ demo: [ClipItem]) { items = demo }

    // MARK: - Sichtbare Liste

    var visible: [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? items : items.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return list.filter(\.pinned) + list.filter { !$0.pinned }
    }

    var selectedItem: ClipItem? {
        let v = visible
        return v.indices.contains(selected) ? v[selected] : nil
    }

    func move(_ delta: Int) {
        let n = visible.count
        guard n > 0 else { return }
        selected = min(max(0, selected + delta), n - 1)
    }

    func resetForOpen() {
        query = ""
        selected = 0
        showSettings = false
        openCount += 1
        pasteAllowed = Paster.isTrusted
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Aktionen

    func pick(_ item: ClipItem, paste: Bool) { onPick?(item, paste) }

    /// Legt den Eintrag in die Zwischenablage und schiebt ihn nach oben
    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
        case .files:
            let urls = item.text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) as NSURL }
            pb.writeObjects(urls)
        case .image:
            if let name = item.image, let data = try? Data(contentsOf: imageURL(name)) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        }
        lastChange = pb.changeCount
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            var it = items.remove(at: i)
            it.date = Date()
            items.insert(it, at: 0)
            save()
        }
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].pinned.toggle()
        save()
    }

    func delete(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        removeFiles(of: items.remove(at: i))
        selected = min(selected, max(0, visible.count - 1))
        save()
    }

    /// Löscht alles außer angehefteten Einträgen
    func clear() {
        items.filter { !$0.pinned }.forEach(removeFiles)
        items.removeAll { !$0.pinned }
        selected = 0
        save()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshTrust() { pasteAllowed = Paster.isTrusted }

    // MARK: - Zwischenablage beobachten

    private static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType", "com.typeit4me.clipping",
        "Pasteboard generator type", "net.antelle.keeweb",
    ]

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        let types = (pb.types ?? []).map(\.rawValue)
        // Passwortmanager & Co. markieren geheime Inhalte – die landen nie im Verlauf
        if types.contains(where: Self.ignoredTypes.contains) { return }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front == Bundle.main.bundleIdentifier { return }

        var item: ClipItem?
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            item = ClipItem(kind: .files, text: urls.map(\.path).joined(separator: "\n"), app: front)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            item = ClipItem(kind: .text, text: s, app: front)
        } else if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
                  let img = NSImage(data: data), let png = Self.png(img) {
            let name = UUID().uuidString + ".png"
            try? png.write(to: imageURL(name))
            let px = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
            item = ClipItem(kind: .image, text: "", image: name, imageSize: px, app: front)
        }
        guard let item else { return }
        add(item)
        onCopied?(item)
    }

    private func add(_ new: ClipItem) {
        var new = new
        if new.kind != .image, let i = items.firstIndex(where: { $0.kind == new.kind && $0.text == new.text }) {
            new.pinned = items[i].pinned
            new.id = items[i].id
            items.remove(at: i)
        }
        items.insert(new, at: 0)
        trim()
        save()
    }

    private func trim() {
        var unpinned = 0
        items = items.filter { item in
            if item.pinned { return true }
            unpinned += 1
            if unpinned > maxItems { removeFiles(of: item); return false }
            return true
        }
    }

    private func removeFiles(of item: ClipItem) {
        guard let name = item.image else { return }
        try? FileManager.default.removeItem(at: imageURL(name))
        thumbs[name] = nil
    }

    // MARK: - Bilder

    func thumbnail(_ item: ClipItem) -> NSImage? {
        guard let name = item.image else { return nil }
        if let t = thumbs[name] { return t }
        let t = NSImage(contentsOf: imageURL(name))
        thumbs[name] = t
        return t
    }

    func cacheThumbnail(_ img: NSImage, for name: String) { thumbs[name] = img }

    private static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Speichern

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = list
    }

    private func save() {
        saveWork?.cancel()
        let snapshot = items
        let url = historyURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: historyURL, options: .atomic) }
    }
}
