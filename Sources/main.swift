import Cocoa
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Model

struct Rule: Codable { var dest: String; var ext: [String]?; var name: String? }
struct Config: Codable { var watch: String; var root: String?; var rules: [Rule]; var delay: Int? }  // delay = minutes new files wait before being sorted
struct Move: Codable { var t: Double; var src: String; var dst: String }

let fm = FileManager.default
let support = ProcessInfo.processInfo.environment["NOOK_SUPPORT"].map { URL(fileURLWithPath: $0) }
    ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nook")
let rulesURL = support.appendingPathComponent("rules.json")
let logURL = support.appendingPathComponent("moves.jsonl")
let tempExt: Set<String> = ["crdownload", "part", "download", "tmp", "opdownload"]

let defaultRules = """
{
  "watch": "~/Downloads",
  "root": "~/Downloads",
  "rules": [
    {"dest": "Installers",      "ext": ["dmg", "pkg", "exe", "msi", "deb", "appimage"]},
    {"dest": "Archives",        "ext": ["zip", "tar.gz", "tgz", "rar", "7z", "gz", "tar"]},
    {"dest": "Screenshots",     "name": "^(screenshot|screen shot|bildschirmfoto)", "ext": ["png"]},
    {"dest": "Images",          "ext": ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"]},
    {"dest": "Video",           "ext": ["mp4", "mov", "mkv", "avi", "webm"]},
    {"dest": "Audio",           "ext": ["mp3", "wav", "flac", "m4a", "aac"]},
    {"dest": "Documents/Invoices", "name": "invoice|rechnung|faktura|receipt"},
    {"dest": "Documents",       "ext": ["pdf", "doc", "docx", "odt", "txt", "md", "rtf", "pages"]},
    {"dest": "Spreadsheets",    "ext": ["xls", "xlsx", "csv", "ods", "numbers"]},
    {"dest": "Slides",          "ext": ["ppt", "pptx", "key", "odp"]},
    {"dest": "Code",            "ext": ["py", "js", "ts", "json", "yaml", "yml", "ipynb", "sh", "html", "css"]}
  ]
}
"""

func logMove(_ m: Move) {
    guard var line = try? JSONEncoder().encode(m) else { return }
    line.append(0x0A)
    try? fm.createDirectory(at: support, withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
    } else { try? line.write(to: logURL) }
}

func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

func unique(_ u: URL) -> URL {
    guard fm.fileExists(atPath: u.path) else { return u }
    let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
    var i = 1
    while true {
        let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
        let c = u.deletingLastPathComponent().appendingPathComponent(n)
        if !fm.fileExists(atPath: c.path) { return c }
        i += 1
    }
}

// MARK: - Engine

final class Engine {
    private(set) var config: Config
    private var cfgStamp: Date?
    private var pending: [String: Int] = [:]   // path -> size at previous tick
    private let q = DispatchQueue(label: "nook.engine")
    private var timer: DispatchSourceTimer?
    var paused = false

    init() {
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: rulesURL.path) { try? defaultRules.write(to: rulesURL, atomically: true, encoding: .utf8) }
        config = (try? JSONDecoder().decode(Config.self, from: Data(defaultRules.utf8)))!
        reload()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 2, repeating: 3)
        t.setEventHandler { [weak self] in if self?.paused == false { self?.tick(force: false) } }
        t.resume()
        timer = t
    }

    private func reload() {
        let stamp = (try? fm.attributesOfItem(atPath: rulesURL.path)[.modificationDate]) as? Date
        guard stamp != cfgStamp else { return }
        cfgStamp = stamp
        if let d = try? Data(contentsOf: rulesURL), let c = try? JSONDecoder().decode(Config.self, from: d) { config = c }
    }

    private func match(_ file: String) -> String? {
        let low = file.lowercased()
        for r in config.rules {
            if r.ext == nil && r.name == nil { continue }
            if let exts = r.ext, !exts.contains(where: { low.hasSuffix("." + $0.lowercased()) }) { continue }
            if let pat = r.name, low.range(of: pat, options: [.regularExpression, .caseInsensitive]) == nil { continue }
            return r.dest
        }
        return nil
    }

    /// force = skip the "size unchanged since last tick" check (used by Sort Now).
    func tick(force: Bool) {
        reload()
        let dir = expand(config.watch)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey]
        let wait = Double(config.delay ?? 0) * 60
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var seen = Set<String>()
        for u in items {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if tempExt.contains(u.pathExtension.lowercased()) { continue }
            guard let dest = match(u.lastPathComponent) else { continue }
            let size = v.fileSize ?? 0
            seen.insert(u.path)
            if !force, wait > 0, let added = v.addedToDirectoryDate ?? v.creationDate, Date().timeIntervalSince(added) < wait { continue }
            if !force && pending[u.path] != size { pending[u.path] = size; continue }
            if move(u, to: dest) { pending[u.path] = nil; seen.remove(u.path) }
        }
        pending = pending.filter { seen.contains($0.key) }
    }

    private func move(_ u: URL, to dest: String) -> Bool {
        let dir = expand(config.root ?? config.watch).appendingPathComponent(dest)
        let target = unique(dir.appendingPathComponent(u.lastPathComponent))
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.moveItem(at: u, to: target)
        } catch { return false }
        appendLog(Move(t: Date().timeIntervalSince1970, src: u.path, dst: target.path))
        return true
    }

    private func appendLog(_ m: Move) { logMove(m) }

    // MARK: public actions (run on the engine queue)

    func sortNow() { q.async { self.tick(force: true) } }

    func undoLast(done: @escaping (String) -> Void) {
        q.async {
            var lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            var msg = "Nothing to undo"
            while let last = lines.last {
                lines.removeLast()
                guard let m = try? JSONDecoder().decode(Move.self, from: Data(last.utf8)) else { continue }
                if fm.fileExists(atPath: m.dst) {
                    let back = unique(URL(fileURLWithPath: m.src))
                    if (try? fm.moveItem(atPath: m.dst, toPath: back.path)) != nil { msg = "Restored \(back.lastPathComponent)" } else { msg = "Undo failed" }
                    break
                }
            }
            try? (lines.map { $0 + "\n" }.joined()).write(to: logURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { done(msg) }
        }
    }

    func recent(_ n: Int) -> [Move] {
        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
        return lines.suffix(n).reversed().compactMap { try? JSONDecoder().decode(Move.self, from: Data($0.utf8)) }
    }

    var watchPath: String { config.watch }
    var rootPath: String { config.root ?? config.watch }
}

// MARK: - Presets & login item

struct Kind: Identifiable {
    let id: String          // also the default folder name
    let symbol: String
    let ext: [String]
}

let kinds: [Kind] = [
    Kind(id: "Images", symbol: "photo", ext: ["jpg", "jpeg", "png", "gif", "webp", "heic", "svg", "bmp", "tiff"]),
    Kind(id: "Documents", symbol: "doc.text", ext: ["pdf", "doc", "docx", "odt", "txt", "md", "rtf", "pages"]),
    Kind(id: "Spreadsheets", symbol: "tablecells", ext: ["xls", "xlsx", "csv", "ods", "numbers"]),
    Kind(id: "Slides", symbol: "rectangle.on.rectangle", ext: ["ppt", "pptx", "key", "odp"]),
    Kind(id: "Video", symbol: "film", ext: ["mp4", "mov", "mkv", "avi", "webm"]),
    Kind(id: "Audio", symbol: "music.note", ext: ["mp3", "wav", "flac", "m4a", "aac"]),
    Kind(id: "Archives", symbol: "archivebox", ext: ["zip", "tar.gz", "tgz", "rar", "7z", "gz", "tar"]),
    Kind(id: "Installers", symbol: "shippingbox", ext: ["dmg", "pkg", "exe", "msi", "deb", "appimage"]),
    Kind(id: "Code", symbol: "chevron.left.forwardslash.chevron.right", ext: ["py", "js", "ts", "json", "yaml", "yml", "ipynb", "sh", "html", "css"]),
]

let waitChoices: [(minutes: Int, label: String)] = [
    (0, "Immediately"), (1, "After 1 minute"), (5, "After 5 minutes"), (10, "After 10 minutes"),
    (30, "After 30 minutes"), (60, "After 1 hour"), (360, "After 6 hours"), (1440, "After 1 day"), (10080, "After 1 week"),
]

var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

func setLoginItem(_ on: Bool) {
    let s = SMAppService.mainApp
    do { if on { try s.register() } else { try s.unregister() } } catch {}
    if on && s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
}

// MARK: - Settings

struct RuleRow: Identifiable {
    let id = UUID()
    var dest = ""
    var ext = ""
    var name = ""
}

/// Autosaving model shared by both settings panes (like System Settings: no Save button).
final class SettingsModel: ObservableObject {
    @Published var watch = ""
    @Published var root = ""
    @Published var delay = 0   // minutes
    @Published var rows: [RuleRow] = []
    @Published var launchAtLogin = loginEnabled
    private var loading = true
    private var bag = Set<AnyCancellable>()

    init() {
        load()
        objectWillChange
            .filter { [weak self] in self?.loading == false }
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
    }

    private static var defaults: Config { try! JSONDecoder().decode(Config.self, from: Data(defaultRules.utf8)) }

    private func apply(_ c: Config) {
        loading = true
        watch = c.watch
        root = c.root ?? c.watch
        delay = c.delay ?? 0
        rows = c.rules.map { RuleRow(dest: $0.dest, ext: ($0.ext ?? []).joined(separator: ", "), name: Self.displayName($0.name ?? "")) }
        loading = false
    }

    func load() {
        let c = (try? Data(contentsOf: rulesURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        apply(c ?? Self.defaults)
    }

    func resetRules() { rows = Self.defaults.rules.map { RuleRow(dest: $0.dest, ext: ($0.ext ?? []).joined(separator: ", "), name: Self.displayName($0.name ?? "")) } }

    func setLaunchAtLogin(_ on: Bool) {
        setLoginItem(on)
        launchAtLogin = loginEnabled
    }

    func add(_ r: RuleRow) { rows.insert(r, at: 0) }   // newest rule goes on top so it wins

    func add(kind k: Kind) { add(RuleRow(dest: k.id, ext: k.ext.joined(separator: ", "), name: "")) }

    /// Create one rule per dropped file type (skips types already covered by a rule).
    func addRules(forDropped urls: [URL]) {
        for u in urls {
            let e = u.pathExtension.lowercased()
            guard !e.isEmpty, !rows.contains(where: { Self.parseExt($0.ext).contains(e) }) else { continue }
            if let k = kinds.first(where: { $0.ext.contains(e) }) { add(kind: k) }
            else { add(RuleRow(dest: e.uppercased() + " files", ext: e, name: "")) }
        }
    }

    /// Plain words ("invoice, receipt") become a regex; anything that already looks like a regex is kept as is.
    static func nameToRegex(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(where: { "^$()[]*+?\\{}.".contains($0) }) { return t }
        return t.split(whereSeparator: { ",|".contains($0) })
            .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }.joined(separator: "|")
    }

    static func displayName(_ regex: String) -> String {
        regex.contains(where: { "^$()[]*+?\\{}.".contains($0) }) ? regex : regex.replacingOccurrences(of: "|", with: ", ")
    }

    static func parseExt(_ s: String) -> [String] {
        s.split(whereSeparator: { ", ;".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    func regexValid(_ s: String) -> Bool { let r = Self.nameToRegex(s); return r.isEmpty || (try? NSRegularExpression(pattern: r)) != nil }

    /// Writes rules.json. Incomplete rows are skipped in the file but stay visible while being edited.
    private func save() {
        guard !watch.trimmingCharacters(in: .whitespaces).isEmpty, rows.allSatisfy({ regexValid($0.name) }) else { return }
        let rules = rows.compactMap { r -> Rule? in
            let d = r.dest.trimmingCharacters(in: .whitespaces)
            let e = Self.parseExt(r.ext)
            let n = Self.nameToRegex(r.name)
            guard !d.isEmpty, !e.isEmpty || !n.isEmpty else { return nil }
            return Rule(dest: d, ext: e.isEmpty ? nil : e, name: n.isEmpty ? nil : n)
        }
        let r = root.trimmingCharacters(in: .whitespaces)
        let c = Config(watch: watch.trimmingCharacters(in: .whitespaces), root: r.isEmpty ? nil : r, rules: rules, delay: delay == 0 ? nil : delay)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        try? enc.encode(c).write(to: rulesURL, options: .atomic)
    }
}

struct GeneralPane: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        Form {
            Section {
                folderRow("Watch", $m.watch)
                folderRow("Sort into", $m.root)
            } header: {
                Text("Folders")
            } footer: {
                Text("Nook only moves files that are placed directly in the watched folder. Subfolders are never touched.")
            }
            Section {
                Picker("Sort new files", selection: $m.delay) {
                    ForEach(waitChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
            } footer: {
                Text("Recent files stay where they are until they have been in the folder this long. “Sort Now” in the menu ignores the wait.")
            }
            Section {
                Toggle("Open Nook when I log in", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
            } footer: {
                Text("Nook starts quietly in the menu bar when you start your Mac. Keep the app in your Applications folder.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 520, height: 430)
    }

    private func folderRow(_ label: String, _ path: Binding<String>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(path.wrappedValue).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    p.prompt = "Choose"
                    if p.runModal() == .OK, let u = p.url { path.wrappedValue = (u.path as NSString).abbreviatingWithTildeInPath }
                }
            }
        }
    }
}

struct RulesPane: View {
    @ObservedObject var m: SettingsModel
    @State private var confirmReset = false
    @State private var showSheet = false
    @State private var dropping = false

    var body: some View {
        Form {
            Section {
                if m.rows.isEmpty {
                    Text("No rules yet. Use Add Rule, or drop a file here.").foregroundStyle(.secondary)
                }
                ForEach($m.rows) { $r in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Folder", text: $r.dest).textFieldStyle(.plain).fontWeight(.medium)
                            HStack(spacing: 12) {
                                TextField("File types: png, jpg", text: $r.ext)
                                TextField("Name contains: invoice, receipt", text: $r.name)
                                    .foregroundColor(m.regexValid(r.name) ? .secondary : .red)
                            }
                            .textFieldStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        }
                        Button { m.rows.removeAll { $0.id == r.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless).help("Delete rule")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { m.rows.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Rules")
            } footer: {
                Text("New rules go on top, and the first matching rule wins. Drag to reorder. Tip: drop any file here to make a rule for its type.")
            }
            Section {
                HStack {
                    Menu {
                        ForEach(kinds) { k in
                            Button { m.add(kind: k) } label: { Label(k.id, systemImage: k.symbol) }
                        }
                        Divider()
                        Button("Custom Rule…") { showSheet = true }
                    } label: { Label("Add Rule", systemImage: "plus") }
                    .fixedSize()
                    Spacer()
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 640, height: 500)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08)).padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let d = data as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) else { return }
                    DispatchQueue.main.async { m.addRules(forDropped: [u]) }
                }
            }
            return true
        }
        .sheet(isPresented: $showSheet) { AddRuleSheet { m.add($0) } }
        .confirmationDialog("Replace all rules with the defaults?", isPresented: $confirmReset) {
            Button("Reset Rules", role: .destructive) { m.resetRules() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Guided "new rule": pick kinds of files, optionally add words, name the folder.
struct AddRuleSheet: View {
    var onAdd: (RuleRow) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var extra = ""
    @State private var words = ""
    @State private var folder = ""

    private var exts: [String] {
        var out: [String] = []
        for k in kinds where picked.contains(k.id) { out += k.ext }
        for e in SettingsModel.parseExt(extra) where !out.contains(e) { out.append(e) }
        return out
    }
    private var suggested: String {
        kinds.first(where: { picked.contains($0.id) })?.id ?? SettingsModel.parseExt(extra).first.map { $0.uppercased() + " files" } ?? ""
    }
    private var finalFolder: String { folder.trimmingCharacters(in: .whitespaces).isEmpty ? suggested : folder }
    private var canAdd: Bool { (!exts.isEmpty || !SettingsModel.nameToRegex(words).isEmpty) && !finalFolder.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Rule").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Which files?").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(kinds) { k in
                        Toggle(isOn: Binding(get: { picked.contains(k.id) },
                                             set: { if $0 { picked.insert(k.id) } else { picked.remove(k.id) } })) {
                            Label(k.id, systemImage: k.symbol).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .toggleStyle(.button)
                    }
                }
                TextField("Other file types, e.g. epub, mobi", text: $extra).textFieldStyle(.roundedBorder)
                TextField("Only if the name contains (optional), e.g. invoice, receipt", text: $words).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Move them to").font(.headline)
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    TextField(suggested.isEmpty ? "Folder name" : suggested, text: $folder).textFieldStyle(.roundedBorder)
                }
                Text("A folder inside your “Sort into” folder. Use Taxes/2026 for a subfolder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rule") {
                    onAdd(RuleRow(dest: finalFolder.trimmingCharacters(in: .whitespaces),
                                  ext: exts.joined(separator: ", "), name: words))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

struct SearchPane: View {
    @AppStorage("aiSearch") private var enabled = false
    @AppStorage("aiModel") private var model = "gpt-4o-mini"
    @State private var key = Keychain.get("openai") ?? ""

    var body: some View {
        Form {
            Section {
                Toggle("Use OpenAI to understand searches", isOn: $enabled)
                SecureField("API key", text: $key, prompt: Text("sk-…"))
                TextField("Model", text: $model)
            } header: {
                Text("AI Search")
            } footer: {
                Text("In Browse Files, type what you are looking for (for example “invoices from the telekom last month” or “Rechnung pdf bigger than 1 MB”) and press Return. Only the text you type is sent to OpenAI to work out synonyms, languages, dates and sizes. File names and contents never leave your Mac; Spotlight does the searching. Without a key, Nook still understands types, dates and sizes locally.")
            }
            Section {
                HStack {
                    Label(key.isEmpty ? "No key saved" : "Key saved in your Keychain", systemImage: key.isEmpty ? "key" : "key.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Key", role: .destructive) { key = "" }.disabled(key.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 520, height: 430)
        .onChange(of: key) { Keychain.set("openai", $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

func makeSettingsWindow() -> NSWindow {
    let model = SettingsModel()
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar

    func add<V: View>(_ title: String, _ symbol: String, _ view: V) {
        let hc = NSHostingController(rootView: view)
        hc.sizingOptions = [.preferredContentSize]
        hc.title = title
        let item = NSTabViewItem(viewController: hc)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }
    add("General", "gearshape", GeneralPane(m: model))
    add("Rules", "list.bullet.rectangle", RulesPane(m: model))
    add("Search", "sparkles", SearchPane())

    let w = NSWindow(contentViewController: tabs)
    w.styleMask = [.titled, .closable, .miniaturizable]
    w.toolbarStyle = .preference
    w.isReleasedWhenClosed = false

    // Translucent "glass": blur the desktop behind the whole window, titlebar included.
    w.isOpaque = false
    w.backgroundColor = .clear
    w.titlebarAppearsTransparent = true
    if let content = w.contentView, let frame = content.superview {
        let glass = NSVisualEffectView(frame: frame.bounds)
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        frame.addSubview(glass, positioned: .below, relativeTo: content)
    }
    w.center()
    return w
}

// MARK: - UI

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let engine = Engine()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var status = ""

    func applicationDidFinishLaunching(_ n: Notification) {
        installMainMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        engine.start()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if CommandLine.arguments.contains("--browser") { openBrowser() }
        if ProcessInfo.processInfo.environment["NOOK_SUPPORT"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.askLoginOnce() }
        }
    }

    /// First launch only: offer to start Nook at login.
    func askLoginOnce() {
        let key = "askedLoginItem"
        guard !UserDefaults.standard.bool(forKey: key), !loginEnabled else { return }
        UserDefaults.standard.set(true, forKey: key)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Open Nook when you start your Mac?"
        a.informativeText = "Nook lives in the menu bar and keeps your Downloads tidy in the background. You can change this any time in Settings."
        a.addButton(withTitle: "Open at Login")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { setLoginItem(true) }
    }

    @objc func toggleLogin() { setLoginItem(!loginEnabled) }

    var settingsWindow: NSWindow?
    var browserWindow: NSWindow?

    @objc func openBrowser() {
        if browserWindow?.isVisible != true {
            browserWindow = makeBrowserWindow(start: expand(engine.watchPath), root: expand(engine.rootPath))
        }
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.makeKeyAndOrderFront(nil)
    }

    /// Standard Edit/Window menus so ⌘C ⌘V ⌘X ⌘A ⌘Z ⌘W work in text fields and the file browser.
    func installMainMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "Hide Nook", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenuItem(); main.addItem(edit)
        let em = NSMenu(title: "Edit"); edit.submenu = em
        em.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = em.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        em.addItem(.separator())
        em.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        em.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        em.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        em.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let win = NSMenuItem(); main.addItem(win)
        let wm = NSMenu(title: "Window"); win.submenu = wm
        wm.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        wm.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = main
        NSApp.windowsMenu = wm
    }

    @objc func openSettings() {
        if settingsWindow?.isVisible != true { settingsWindow = makeSettingsWindow() }  // fresh load each open
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func updateIcon() {
        let name = engine.paused ? "pause.circle" : "tray.and.arrow.down"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Nook")
        img?.isTemplate = true
        item.button?.image = img
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        let head = NSMenuItem(title: engine.paused ? "Paused" : "Watching \(engine.watchPath)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        if !status.isEmpty { let s = NSMenuItem(title: status, action: nil, keyEquivalent: ""); s.isEnabled = false; m.addItem(s) }
        m.addItem(.separator())
        add(m, engine.paused ? "Resume" : "Pause", #selector(togglePause), symbol: engine.paused ? "play.fill" : "pause.fill")
        add(m, "Sort Now", #selector(sortNow), symbol: "arrow.triangle.2.circlepath")
        add(m, "Undo Last Move", #selector(undo), "z", symbol: "arrow.uturn.backward")

        let sub = NSMenu()
        let moves = engine.recent(8)
        if moves.isEmpty { sub.addItem(withTitle: "No moves yet", action: nil, keyEquivalent: "").isEnabled = false }
        for mv in moves {
            let dir = URL(fileURLWithPath: mv.dst).deletingLastPathComponent().lastPathComponent
            let it = NSMenuItem(title: "\(URL(fileURLWithPath: mv.dst).lastPathComponent)  →  \(dir)", action: #selector(reveal(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = mv.dst
            sub.addItem(it)
        }
        let recent = NSMenuItem(title: "Recent Moves", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recent.submenu = sub
        m.addItem(recent)

        m.addItem(.separator())
        add(m, "Browse Files…", #selector(openBrowser), "b", symbol: "folder")
        add(m, "Open Watched Folder in Finder", #selector(openFolder), symbol: "arrow.up.forward.app")
        m.addItem(.separator())
        let login = add(m, "Open at Login", #selector(toggleLogin), symbol: "power")
        login.state = loginEnabled ? .on : .off
        add(m, "Settings…", #selector(openSettings), ",", symbol: "gearshape")
        add(m, "About Nook", #selector(about), symbol: "info.circle")
        m.addItem(.separator())
        add(m, "Quit Nook", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
    }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ sel: Selector, _ key: String = "", symbol: String? = nil, target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = target ?? self
        if let symbol { it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        m.addItem(it)
        return it
    }

    @objc func togglePause() { engine.paused.toggle(); status = ""; updateIcon() }
    @objc func sortNow() { status = "Sorted"; engine.sortNow() }
    @objc func undo() { engine.undoLast { self.status = $0 } }
    @objc func reveal(_ s: NSMenuItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.representedObject as! String)]) }
    @objc func openFolder() { NSWorkspace.shared.open(expand(engine.watchPath)) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
