import SwiftUI
import AppKit

extension Color {
    static let clip = Color(red: 0.46, green: 0.37, blue: 0.95)
    static let clipDark = Color(red: 0.30, green: 0.21, blue: 0.78)
}

/// App-Symbole und -Namen zu Bundle-IDs (zwischengespeichert)
enum AppInfo {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func icon(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let i = icons[id] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        icons[id] = i
        return i
    }

    static func name(_ id: String?) -> String? {
        guard let id else { return nil }
        if let n = names[id] { return n }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let n = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[id] = n
        return n
    }
}

struct ClipPanel: View {
    @ObservedObject var store: ClipStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.showSettings { SettingsView(store: store) } else { list }
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { searchFocused = true }
        .onChange(of: store.openCount) { searchFocused = true }
        .onChange(of: store.showSettings) { _, s in if !s { searchFocused = true } }
    }

    // MARK: Kopf mit Suche

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Verlauf durchsuchen", text: $store.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
            Text(HotKey.options[min(store.hotkey, HotKey.options.count - 1)].label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Liste

    private var list: some View {
        let items = store.visible
        return Group {
            if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: store.query.isEmpty ? "list.clipboard" : "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                    Text(store.query.isEmpty ? "Noch nichts kopiert" : "Keine Treffer")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                if idx > 0, item.pinned != items[idx - 1].pinned {
                                    Divider().padding(.vertical, 3).padding(.horizontal, 6)
                                }
                                ClipRow(store: store, item: item, index: idx, selected: idx == store.selected)
                                    .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(items.count) * 46 + 14, 430))
                    .onChange(of: store.selected) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
    }

    // MARK: Fuß

    private var footer: some View {
        HStack(spacing: 12) {
            if store.showSettings {
                Button { store.showSettings = false } label: { Label("Zurück", systemImage: "chevron.left") }
            } else {
                Text("↩ einfügen · ⌘P anheften · ⌥⌫ löschen")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !store.showSettings {
                Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Einstellungen")
            }
            Button("Beenden") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct ClipRow: View {
    @ObservedObject var store: ClipStore
    let item: ClipItem
    let index: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? .white.opacity(0.9) : Color.clip)
            }
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(selected ? .white.opacity(0.8) : Color.secondary.opacity(0.7))
            }
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? AnyShapeStyle(LinearGradient(colors: [.clip, .clipDark],
                                                              startPoint: .leading, endPoint: .trailing))
                               : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { if $0 { store.selected = index } }
        .onTapGesture { store.pick(item, paste: true) }
        .contextMenu {
            Button("Einfügen") { store.pick(item, paste: true) }
            Button("Nur kopieren") { store.pick(item, paste: false) }
            Divider()
            Button(item.pinned ? "Lösen" : "Anheften") { store.togglePin(item) }
            Button("Löschen", role: .destructive) { store.delete(item) }
        }
    }

    @ViewBuilder private var leading: some View {
        if item.kind == .image, let img = store.thumbnail(item) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
        } else if let icon = AppInfo.icon(item.app) {
            Image(nsImage: icon).resizable().frame(width: 28, height: 28).frame(width: 30)
        } else {
            Image(systemName: item.kind == .files ? "doc" : "text.alignleft")
                .font(.system(size: 13))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
    }

    private var title: String {
        switch item.kind {
        case .image: return "Bild"
        case .files:
            let paths = item.text.split(separator: "\n")
            let first = (String(paths.first ?? "") as NSString).lastPathComponent
            return paths.count > 1 ? "\(first) + \(paths.count - 1) weitere" : first
        case .text:
            // Zeilen zusammenziehen, Einrückungen weg
            return item.text.prefix(400)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ⏎ ")
                .replacingOccurrences(of: "\t", with: " ")
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let name = AppInfo.name(item.app) { parts.append(name) }
        switch item.kind {
        case .image:
            if let s = item.imageSize { parts.append("\(Int(s.width)) × \(Int(s.height))") }
        case .files:
            parts.append((item.text.split(separator: "\n").first.map { ($0 as NSString).deletingLastPathComponent } ?? "")
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        case .text:
            let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
            parts.append(lines > 1 ? "\(lines) Zeilen" : "\(item.text.count) Zeichen")
        }
        parts.append(Self.ago(item.date))
        return parts.joined(separator: " · ")
    }

    static func ago(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "gerade eben" }
        if s < 3600 { return "vor \(s / 60) Min" }
        if s < 86400 { return "vor \(s / 3600) Std" }
        if s < 172800 { return "gestern" }
        let f = DateFormatter()
        f.dateFormat = "d. MMM"
        f.locale = Locale(identifier: "de_DE")
        return f.string(from: d)
    }
}

struct SettingsView: View {
    @ObservedObject var store: ClipStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("Tastenkürzel") {
                Picker("", selection: $store.hotkey) {
                    ForEach(HotKey.options.indices, id: \.self) { Text(HotKey.options[$0].label).tag($0) }
                }
            }
            row("Verlauf") {
                Picker("", selection: $store.maxItems) {
                    ForEach(ClipStore.sizes, id: \.self) { Text("\($0) Einträge").tag($0) }
                }
            }
            row("Beim Kopieren") {
                Picker("", selection: $store.feedback) {
                    Text("Hinweis am Mauszeiger").tag(0)
                    Text("Nur Symbol in der Menüleiste").tag(1)
                    Text("Nichts").tag(2)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Direkt einfügen (sonst nur kopieren)", isOn: $store.autoPaste)
                if store.autoPaste && !store.pasteAllowed {
                    HStack(spacing: 4) {
                        Text("Braucht die Freigabe unter Bedienungshilfen.")
                        Button("Öffnen") { Paster.requestTrust(); Paster.openSettings() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
                }
            }
            Toggle("Bei Anmeldung starten", isOn: Binding(get: { store.launchAtLogin },
                                                          set: { store.setLaunchAtLogin($0) }))
            Divider()
            HStack {
                Text("Passwörter aus Passwortmanagern werden nie gespeichert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Button(role: .destructive) { store.clear() } label: {
                Label("Verlauf leeren (Angeheftetes bleibt)", systemImage: "trash")
            }
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .onAppear { store.refreshTrust() }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title)
            Spacer()
            content().labelsHidden().fixedSize()
        }
    }
}

/// Der kleine „Kopiert“-Hinweis
struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, Color.clip)
                .font(.system(size: 14))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        .padding(4)
    }

    @MainActor static func host(_ text: String) -> NSView {
        let v = NSHostingView(rootView: ToastView(text: text))
        v.frame.size = v.fittingSize
        return v
    }
}
