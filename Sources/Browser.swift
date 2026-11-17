import SwiftUI
import AppKit

// MARK: - Model

struct FileItem: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    let name: String
    let isDir: Bool
    let size: Int64
    let date: Date
    let kind: String
    var sizeText: String { isDir ? "—" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

struct Place: Identifiable, Hashable {
    let name: String
    let symbol: String
    let url: URL
    var id: URL { url }
}

final class BrowserModel: ObservableObject {
    @Published var url: URL
    @Published var items: [FileItem] = []
    @Published var selection = Set<URL>()
    @Published var search = ""
    @Published var sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard)]
    @Published var showHidden = false { didSet { reload() } }
    @Published var renaming: URL?
    @Published var message = ""
    @Published var places: [Place] = []
    @Published var nookPlaces: [Place] = []

    let rootURL: URL
    private var back: [URL] = []
    private var forward: [URL] = []
    private var cutURLs: Set<URL> = []
    private var watcher: DispatchSourceFileSystemObject?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    init(start: URL, root: URL) {
        url = start
        rootURL = root
        let home = fm.homeDirectoryForCurrentUser
        places = [
            Place(name: "Home", symbol: "house", url: home),
            Place(name: "Desktop", symbol: "menubar.dock.rectangle", url: home.appendingPathComponent("Desktop")),
            Place(name: "Documents", symbol: "doc", url: home.appendingPathComponent("Documents")),
            Place(name: "Downloads", symbol: "arrow.down.circle", url: home.appendingPathComponent("Downloads")),
            Place(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
        ]
        reload()
        watch()
    }

    deinit { watcher?.cancel() }

    var visible: [FileItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return list.sorted(using: sortOrder)
    }

    var ancestors: [URL] {
        var out: [URL] = [], u = url
        while true { out.append(u); if u.path == "/" { break }; u = u.deletingLastPathComponent() }
        return out
    }

    // MARK: loading

    func reload() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        do {
            let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
            items = urls.map { u in
                let v = try? u.resourceValues(forKeys: Set(keys))
                let dir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
                return FileItem(url: u, name: u.lastPathComponent, isDir: dir, size: Int64(v?.fileSize ?? 0),
                                date: v?.contentModificationDate ?? .distantPast, kind: v?.localizedTypeDescription ?? "")
            }
            message = ""
        } catch {
            items = []
            message = "Nook can't read this folder."
        }
        selection = selection.filter { s in items.contains { $0.url == s } }
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        nookPlaces = dirs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { Place(name: $0.lastPathComponent, symbol: "folder", url: $0) }
    }

    private func watch() {
        watcher?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in self?.reload() }
        s.setCancelHandler { close(fd) }
        s.resume()
        watcher = s
    }

    // MARK: navigation

    func navigate(to target: URL, push: Bool = true) {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else { return }
        if push, target != url { back.append(url); forward = [] }
        url = target
        selection = []
        search = ""
        reload()
        watch()
    }

    func goBack() { guard let u = back.popLast() else { return }; forward.append(url); navigate(to: u, push: false) }
    func goForward() { guard let u = forward.popLast() else { return }; back.append(url); navigate(to: u, push: false) }
    func goUp() { navigate(to: url.deletingLastPathComponent()) }

    // MARK: actions

    func open(_ urls: Set<URL>) {
        if urls.count == 1, let u = urls.first, items.first(where: { $0.url == u })?.isDir == true { navigate(to: u); return }
        for u in urls { NSWorkspace.shared.open(u) }
    }

    func reveal(_ urls: Set<URL>) { NSWorkspace.shared.activateFileViewerSelecting(Array(urls)) }

    func quickLook(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p"] + urls.map(\.path)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func copyToPasteboard(_ urls: Set<URL>, cut: Bool = false) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(Array(urls) as [NSURL])
        cutURLs = cut ? urls : []
    }

    var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func paste() {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        let moving = !cutURLs.isEmpty && Set(urls) == cutURLs
        transfer(urls, into: url, copy: !moving)
        if moving { cutURLs = [] }
    }

    /// Move (or copy) files into a folder. Moves are written to the Nook log so "Undo Last Move" works.
    func transfer(_ urls: [URL], into dir: URL, copy: Bool) {
        for u in urls {
            if dir.path == u.path || dir.path.hasPrefix(u.path + "/") { continue }          // not into itself
            if !copy && u.deletingLastPathComponent().path == dir.path { continue }          // already there
            let target = unique(dir.appendingPathComponent(u.lastPathComponent))
            do {
                if copy { try fm.copyItem(at: u, to: target) } else {
                    try fm.moveItem(at: u, to: target)
                    logMove(Move(t: Date().timeIntervalSince1970, src: u.path, dst: target.path))
                }
            } catch { message = "Could not \(copy ? "copy" : "move") \(u.lastPathComponent)" }
        }
        reload()
    }

    func trash(_ urls: Set<URL>) {
        for u in urls { try? fm.trashItem(at: u, resultingItemURL: nil) }
        selection = []
        reload()
    }

    func duplicate(_ urls: Set<URL>) {
        for u in urls {
            let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
            let name = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
            try? fm.copyItem(at: u, to: unique(u.deletingLastPathComponent().appendingPathComponent(name)))
        }
        reload()
    }

    func compress(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let names = urls.map(\.lastPathComponent).sorted()
        let out = unique(url.appendingPathComponent(urls.count == 1 ? "\(names[0]).zip" : "Archive.zip"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = url
        p.arguments = ["-r", "-q", out.path] + names
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in DispatchQueue.main.async { self.reload() } }
        try? p.run()
    }

    func newFolder() {
        let u = unique(url.appendingPathComponent("untitled folder"))
        do {
            try fm.createDirectory(at: u, withIntermediateDirectories: false)
            reload()
            selection = [u]
            renaming = u
        } catch { message = "Could not create folder" }
    }

    func rename(_ u: URL, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.contains("/"), n != u.lastPathComponent else { return }
        let target = u.deletingLastPathComponent().appendingPathComponent(n)
        guard !fm.fileExists(atPath: target.path) else { message = "“\(n)” already exists"; return }
        do { try fm.moveItem(at: u, to: target); reload(); selection = [target] }
        catch { message = "Could not rename" }
    }
}

// MARK: - View

struct BrowserView: View {
    @StateObject var m: BrowserModel
    @State private var newName = ""
    @FocusState private var tableFocused: Bool

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            VStack(spacing: 0) {
                header
                Divider()
                table
                Divider()
                footer
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 780, minHeight: 440)
        .navigationTitle(m.url.lastPathComponent.isEmpty ? "Macintosh HD" : m.url.lastPathComponent)
        .alert("Rename", isPresented: Binding(get: { m.renaming != nil }, set: { if !$0 { m.renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let u = m.renaming { m.rename(u, to: newName) }; m.renaming = nil }
            Button("Cancel", role: .cancel) { m.renaming = nil }
        }
        .onChange(of: m.renaming) { newName = $0?.lastPathComponent ?? "" }
    }

    // MARK: sidebar

    private var sidebar: some View {
        List(selection: Binding<URL?>(get: { m.url }, set: { if let u = $0 { m.navigate(to: u) } })) {
            Section("Favorites") { ForEach(m.places) { row($0) } }
            if !m.nookPlaces.isEmpty { Section("Nook") { ForEach(m.nookPlaces) { row($0) } } }
        }
        .listStyle(.sidebar)
    }

    private func row(_ p: Place) -> some View {
        Label(p.name, systemImage: p.symbol)
            .tag(p.url)
            .dropDestination(for: URL.self) { urls, _ in
                m.transfer(urls, into: p.url, copy: NSEvent.modifierFlags.contains(.option)); return true
            }
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 6) {
            Button { m.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!m.canGoBack)
                .keyboardShortcut("[", modifiers: .command).help("Back")
            Button { m.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!m.canGoForward)
                .keyboardShortcut("]", modifiers: .command).help("Forward")
            Button { m.goUp() } label: { Image(systemName: "chevron.up") }.disabled(!m.canGoUp)
                .keyboardShortcut(.upArrow, modifiers: .command).help("Enclosing folder")

            Menu {
                ForEach(m.ancestors, id: \.self) { u in
                    Button { m.navigate(to: u) } label: { Label(u.lastPathComponent.isEmpty ? "Macintosh HD" : u.lastPathComponent, systemImage: "folder") }
                }
            } label: {
                Label(m.url.lastPathComponent.isEmpty ? "Macintosh HD" : m.url.lastPathComponent, systemImage: "folder.fill")
            }
            .menuStyle(.borderlessButton).fixedSize().padding(.leading, 6)

            Spacer()

            Button { m.newFolder() } label: { Image(systemName: "folder.badge.plus") }
                .keyboardShortcut("n", modifiers: [.command, .shift]).help("New Folder (⇧⌘N)")
            Button { m.showHidden.toggle() } label: { Image(systemName: m.showHidden ? "eye.fill" : "eye") }
                .help("Show hidden files")
            Button { m.reveal([m.url]) } label: { Image(systemName: "arrow.up.forward.app") }.help("Open in Finder")

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $m.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .frame(width: 190)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text(m.message.isEmpty
                 ? "\(m.visible.count) items" + (m.selection.isEmpty ? "" : " · \(m.selection.count) selected")
                 : m.message)
            Spacer()
            Text((m.url.path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.head)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }

    // MARK: table

    private var table: some View {
        Table(of: FileItem.self, selection: $m.selection, sortOrder: $m.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: icon(item.url)).resizable().frame(width: 18, height: 18)
                    Text(item.name).lineLimit(1)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard item.isDir else { return false }
                    m.transfer(urls, into: item.url, copy: NSEvent.modifierFlags.contains(.option)); return true
                }
            }
            TableColumn("Date Modified", value: \.date) { Text($0.date == .distantPast ? "—" : $0.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 150)
            TableColumn("Size", value: \.size) { Text($0.sizeText).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { Text($0.kind).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 130)
        } rows: {
            ForEach(m.visible) { item in
                TableRow(item).itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .focused($tableFocused)
        .contextMenu(forSelectionType: URL.self) { sel in menu(for: sel) } primaryAction: { m.open($0) }
        .onCopyCommand { provide(m.selection) }
        .onCutCommand { m.copyToPasteboard(m.selection, cut: true); return provide(m.selection) }
        .onPasteCommand(of: [.fileURL]) { _ in m.paste() }
        .onDeleteCommand { m.trash(m.selection) }
        .dropDestination(for: URL.self) { urls, _ in
            m.transfer(urls, into: m.url, copy: NSEvent.modifierFlags.contains(.option)); return true
        }
        .onAppear { tableFocused = true }
    }

    @ViewBuilder
    private func menu(for sel: Set<URL>) -> some View {
        if sel.isEmpty {
            Button("New Folder") { m.newFolder() }
            Button("Paste") { m.paste() }.disabled(!m.canPaste)
        } else {
            Button("Open") { m.open(sel) }
            Button("Quick Look") { m.quickLook(sel) }
            Button("Show in Finder") { m.reveal(sel) }
            Divider()
            Menu("Move To") {
                ForEach(m.nookPlaces + m.places) { p in
                    Button { m.transfer(Array(sel), into: p.url, copy: false) } label: { Label(p.name, systemImage: p.symbol) }
                }
            }
            Divider()
            Button("Copy") { m.copyToPasteboard(sel) }
            Button("Cut") { m.copyToPasteboard(sel, cut: true) }
            Button("Paste") { m.paste() }.disabled(!m.canPaste)
            Button("Duplicate") { m.duplicate(sel) }
            Button("Compress") { m.compress(sel) }
            if sel.count == 1, let u = sel.first { Button("Rename…") { m.renaming = u } }
            Divider()
            Button("Move to Trash", role: .destructive) { m.trash(sel) }
        }
    }

    private func provide(_ urls: Set<URL>) -> [NSItemProvider] { urls.map { NSItemProvider(object: $0 as NSURL) } }

    private func icon(_ u: URL) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: u.path)
        i.size = NSSize(width: 18, height: 18)
        return i
    }
}

func makeBrowserWindow(start: URL, root: URL) -> NSWindow {
    let hc = NSHostingController(rootView: BrowserView(m: BrowserModel(start: start, root: root)))
    let w = NSWindow(contentViewController: hc)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    w.isReleasedWhenClosed = false
    w.setContentSize(NSSize(width: 960, height: 580))
    w.setFrameAutosaveName("NookBrowser")
    w.center()
    return w
}
