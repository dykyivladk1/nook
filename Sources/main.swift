import Cocoa
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Model

struct Rule: Codable { var dest: String; var ext: [String]?; var name: String? }
struct Config: Codable { var watch: String; var root: String?; var rules: [Rule] }
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
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var seen = Set<String>()
        for u in items {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if tempExt.contains(u.pathExtension.lowercased()) { continue }
            guard let dest = match(u.lastPathComponent) else { continue }
            let size = v.fileSize ?? 0
            seen.insert(u.path)
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

    private func appendLog(_ m: Move) {
        guard var line = try? JSONEncoder().encode(m) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else { try? line.write(to: logURL) }
    }

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
    @Published var rows: [RuleRow] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
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
        rows = c.rules.map { RuleRow(dest: $0.dest, ext: ($0.ext ?? []).joined(separator: ", "), name: $0.name ?? "") }
        loading = false
    }

    func load() {
        let c = (try? Data(contentsOf: rulesURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        apply(c ?? Self.defaults)
    }

    func resetRules() { rows = Self.defaults.rules.map { RuleRow(dest: $0.dest, ext: ($0.ext ?? []).joined(separator: ", "), name: $0.name ?? "") } }

    func setLaunchAtLogin(_ on: Bool) {
        let s = SMAppService.mainApp
        do { if on { try s.register() } else { try s.unregister() } } catch {}
        launchAtLogin = s.status == .enabled
    }

    static func parseExt(_ s: String) -> [String] {
        s.split(whereSeparator: { ", ;".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    func regexValid(_ s: String) -> Bool { s.isEmpty || (try? NSRegularExpression(pattern: s)) != nil }

    /// Writes rules.json. Incomplete rows are skipped in the file but stay visible while being edited.
    private func save() {
        guard !watch.trimmingCharacters(in: .whitespaces).isEmpty, rows.allSatisfy({ regexValid($0.name) }) else { return }
        let rules = rows.compactMap { r -> Rule? in
            let d = r.dest.trimmingCharacters(in: .whitespaces)
            let e = Self.parseExt(r.ext)
            let n = r.name.trimmingCharacters(in: .whitespaces)
            guard !d.isEmpty, !e.isEmpty || !n.isEmpty else { return nil }
            return Rule(dest: d, ext: e.isEmpty ? nil : e, name: n.isEmpty ? nil : n)
        }
        let r = root.trimmingCharacters(in: .whitespaces)
        let c = Config(watch: watch.trimmingCharacters(in: .whitespaces), root: r.isEmpty ? nil : r, rules: rules)
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
                Toggle("Open Nook at login", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 520, height: 330)
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

    var body: some View {
        Form {
            Section {
                ForEach($m.rows) { $r in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Folder", text: $r.dest).textFieldStyle(.plain).fontWeight(.medium)
                            HStack(spacing: 12) {
                                TextField("Extensions: png, jpg", text: $r.ext)
                                TextField("Name matches (regex)", text: $r.name)
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
                Text("The first matching rule wins. Drag to reorder. Changes are saved automatically.")
            }
            Section {
                HStack {
                    Button { m.rows.append(RuleRow()) } label: { Label("Add Rule", systemImage: "plus") }
                    Spacer()
                    Button("Reset to Defaults…") { confirmReset = true }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(width: 640, height: 500)
        .confirmationDialog("Replace all rules with the defaults?", isPresented: $confirmReset) {
            Button("Reset Rules", role: .destructive) { m.resetRules() }
            Button("Cancel", role: .cancel) {}
        }
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
        menu.delegate = self
        item.menu = menu
        updateIcon()
        engine.start()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    var settingsWindow: NSWindow?

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
        add(m, "Open Watched Folder", #selector(openFolder), symbol: "folder")
        m.addItem(.separator())
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
