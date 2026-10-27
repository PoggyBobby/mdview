import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Constants / preferences

let appName = "MDView"
let markdownType = UTType("net.daringfireball.markdown") ?? .plainText
let mdExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]

enum Prefs {
    static let d = UserDefaults.standard
    static var zoom: CGFloat {
        get { let z = d.double(forKey: "zoom"); return z > 0 ? CGFloat(z) : 1 }
        set { d.set(Double(newValue), forKey: "zoom") }
    }
    static var tocOpen: Bool {
        get { d.bool(forKey: "tocOpen") }
        set { d.set(newValue, forKey: "tocOpen") }
    }
    static var appearance: String {          // "system" | "light" | "dark"
        get { d.string(forKey: "appearance") ?? "system" }
        set { d.set(newValue, forKey: "appearance") }
    }
    static var editorApp: String? { d.string(forKey: "EditorApp") }   // name, bundle id, or path

    static func scroll(for url: URL) -> Int {
        ((d.dictionary(forKey: "scroll") as? [String: [Int]])?[url.path])?.first ?? 0
    }
    static func setScroll(_ y: Int, for url: URL) {
        var all = (d.dictionary(forKey: "scroll") as? [String: [Int]]) ?? [:]
        all[url.path] = [y, Int(Date().timeIntervalSince1970)]
        if all.count > 400 {
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(all.count - 300)
            for (k, _) in oldest { all[k] = nil }
        }
        d.set(all, forKey: "scroll")
    }
}

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - HTML template

enum Template {
    static let shell: String = {
        let res = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        func read(_ name: String) -> String {
            (try? String(contentsOf: res.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }
        return read("viewer.html")
            .replacingOccurrences(of: "@@MARKED@@", with: read("vendor/marked.umd.js"))
            .replacingOccurrences(of: "@@HLJS@@", with: read("vendor/highlight.min.js"))
            .replacingOccurrences(of: "@@APP@@", with: read("app.js"))
    }()

    /// JSON string literal safe to embed inside a <script> block (JSONSerialization escapes "/" so "</script>" cannot occur).
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]) else { return "\"\"" }
        var json = String(decoding: data, as: UTF8.self)
        json.removeFirst(); json.removeLast()
        return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func html(markdown: String, fileURL: URL, scrollY: Int, tocOpen: Bool) -> String {
        shell
            .replacingOccurrences(of: "@@NONCE@@", with: UUID().uuidString)
            .replacingOccurrences(of: "@@BASE@@", with: escapeHTML(fileURL.deletingLastPathComponent().absoluteString))
            .replacingOccurrences(of: "@@TITLE@@", with: escapeHTML(fileURL.lastPathComponent))
            .replacingOccurrences(of: "@@BODYCLASS@@", with: tocOpen ? "toc-open" : "")
            .replacingOccurrences(of: "@@SCROLL@@", with: String(scrollY))
            .replacingOccurrences(of: "@@MD@@", with: jsString(markdown))
    }
}

// MARK: - Script message proxy (avoids the WKUserContentController retain cycle)

final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

// MARK: - Document window

final class Document: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let url: URL
    let window: NSWindow
    let webView: WKWebView
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?
    private var tempFile: URL?
    private var lastContent = ""
    private var pendingAnchor: String?
    private var pageLoaded = false
    static let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MDView", isDirectory: true)
    var snapshotPath: String?          // debug: --snapshot <png|pdf>
    private var exporting = false

    init(url: URL, anchor: String? = nil) {
        self.url = url
        self.pendingAnchor = anchor
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 760), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        config.userContentController.add(MessageProxy(self), name: "mdv")
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false
        webView.pageZoom = Prefs.zoom
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.autoresizingMask = [.width, .height]

        window.title = url.lastPathComponent
        window.representedURL = url
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.tabbingIdentifier = "MDViewDocument"
        window.setFrameAutosaveName("MDViewWindow")
        applyAppearance()
        load()
        startWatching()
    }

    deinit { refreshTimer?.invalidate() }

    // MARK: Loading / refreshing

    private func readMarkdown() -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        var enc = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &enc) { return s }
        if let d = try? Data(contentsOf: url), let s = String(data: d, encoding: .isoLatin1) { return s }
        return nil
    }

    func load() {
        let md = readMarkdown() ?? "> **MDView:** could not read `\(url.path)`."
        lastContent = md
        let html = Template.html(markdown: md, fileURL: url, scrollY: Prefs.scroll(for: url), tocOpen: Prefs.tocOpen)
        if let old = tempFile { try? FileManager.default.removeItem(at: old) }
        try? FileManager.default.createDirectory(at: Document.tempDirectory, withIntermediateDirectories: true)
        let tmp = Document.tempDirectory.appendingPathComponent(UUID().uuidString + ".html")
        do { try html.write(to: tmp, atomically: true, encoding: .utf8) } catch { NSSound.beep(); return }
        tempFile = tmp
        pageLoaded = false
        webView.loadFileURL(tmp, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in self?.refresh() }
    }

    func refresh(force: Bool = false) {
        guard let md = readMarkdown() else { window.title = url.lastPathComponent + " (missing)"; return }
        window.title = url.lastPathComponent
        guard force || md != lastContent else { return }
        lastContent = md
        guard pageLoaded else { return }
        webView.evaluateJavaScript("MDV.render(\(Template.jsString(md)))")
    }

    func scrollTo(anchor: String) {
        if pageLoaded { webView.evaluateJavaScript("MDV.scrollToHeading(\(Template.jsString(anchor)))") }
        else { pendingAnchor = anchor }
    }

    // MARK: File watching

    private func startWatching() {
        stopWatching()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                // Atomic-save editors replace the file: re-arm on the new inode after a moment.
                self.stopWatching()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startWatching(); self?.scheduleRefresh()
                }
            } else {
                self.scheduleRefresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func stopWatching() { watcher?.cancel(); watcher = nil }

    // MARK: Appearance / zoom

    func applyAppearance() {
        switch Prefs.appearance {
        case "light": window.appearance = NSAppearance(named: .aqua)
        case "dark":  window.appearance = NSAppearance(named: .darkAqua)
        default:      window.appearance = nil
        }
    }

    // MARK: Menu actions (reached through the responder chain as window delegate)

    @objc func reloadDocument(_ sender: Any?) { refresh(force: true) }
    @objc func revealInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc func editInEditor(_ sender: Any?) { AppDelegate.shared.edit(url) }
    @objc func toggleOutline(_ sender: Any?) { webView.evaluateJavaScript("MDV.toggleTOC()") }
    @objc func findInPage(_ sender: Any?) { webView.evaluateJavaScript("MDV.find()") }
    @objc func findNext(_ sender: Any?) { webView.evaluateJavaScript("MDV.findNext()") }
    @objc func findPrevious(_ sender: Any?) { webView.evaluateJavaScript("MDV.findPrev()") }
    @objc func copyPath(_ sender: Any?) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
    }
    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let out = panel.url, let self else { return }
            self.writePDF(to: out) { ok in if !ok { NSSound.beep() } }
        }
    }
    func writePDF(to out: URL, completion: @escaping (Bool) -> Void) {
        exporting = true
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            self?.exporting = false
            if case .success(let data) = result, (try? data.write(to: out)) != nil { completion(true) } else { completion(false) }
        }
    }
    @objc func printDocument(_ sender: Any?) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.topMargin = 40; info.bottomMargin = 40; info.leftMargin = 40; info.rightMargin = 40
        let op = webView.printOperation(with: info)
        op.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Wikilinks

    private func resolveWikilink(_ name: String) -> URL? {
        let fm = FileManager.default
        let target = name.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let hasExt = !(target as NSString).pathExtension.isEmpty
        let candidates = hasExt ? [target] : [target + ".md", target]
        let dir = url.deletingLastPathComponent()
        for c in candidates {
            let u = dir.appendingPathComponent(c)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
        }
        // Vault-wide lookup: nearest ancestor containing ".obsidian", else the file's own folder.
        var root = dir
        var probe = dir
        for _ in 0..<10 {
            if fm.fileExists(atPath: probe.appendingPathComponent(".obsidian").path) { root = probe; break }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        let wanted = candidates.map { $0.lowercased() }
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var seen = 0
        for case let f as URL in en {
            seen += 1; if seen > 60_000 { break }
            let p = f.path.lowercased()
            for w in wanted where p.hasSuffix("/" + w) {
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return f }
            }
        }
        return nil
    }

    private func openWikilink(_ target: String, anchor: String) {
        guard let u = resolveWikilink(target) else { NSSound.beep(); return }
        if mdExtensions.contains(u.pathExtension.lowercased()) { AppDelegate.shared.open(u, anchor: anchor.isEmpty ? nil : anchor) }
        else { NSWorkspace.shared.open(u) }
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "scroll":   if !exporting, let y = body["y"] as? Int { Prefs.setScroll(y, for: url) }
        case "toc":      Prefs.tocOpen = body["open"] as? Bool ?? false
        case "wikilink": if let t = body["target"] as? String { openWikilink(t, anchor: body["anchor"] as? String ?? "") }
        case "copy":     if let t = body["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        case "edit":     AppDelegate.shared.edit(url)
        default: break
        }
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = action.request.url else { decisionHandler(.cancel); return }
        if target.isFileURL, let tmp = tempFile, target.path == tmp.path { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        AppDelegate.shared.handle(link: target)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { AppDelegate.shared.handle(link: u) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        if let a = pendingAnchor { pendingAnchor = nil; scrollTo(anchor: a) }
        if let md = readMarkdown(), md != lastContent { lastContent = md; refresh(force: true) }
        if let path = snapshotPath {
            let delay = Double(ProcessInfo.processInfo.environment["MDVIEW_SNAPSHOT_DELAY"] ?? "") ?? 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if path.lowercased().hasSuffix(".pdf") {
                    self.writePDF(to: URL(fileURLWithPath: path)) { ok in print(ok ? "pdf written: \(path)" : "pdf failed"); exit(ok ? 0 : 1) }
                    return
                }
                self.webView.takeSnapshot(with: nil) { image, error in
                    if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: path)); print("snapshot written: \(path)")
                    } else { print("snapshot failed: \(error?.localizedDescription ?? "?")") }
                    exit(0)
                }
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        refreshTimer?.invalidate()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "mdv")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if let t = tempFile { try? FileManager.default.removeItem(at: t) }
        AppDelegate.shared.documentClosed(self)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!
    private(set) var documents: [Document] = []
    private var cascadePoint = NSPoint.zero
    private var appearanceItems: [String: NSMenuItem] = [:]
    private var editItem: NSMenuItem?
    private var recentMenu: NSMenu?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ n: Notification) {
        try? FileManager.default.removeItem(at: Document.tempDirectory)
        buildMenu()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        var args = Array(CommandLine.arguments.dropFirst())
        var snapshot: String?
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { snapshot = args[i + 1]; args.removeSubrange(i...i + 1) }
        for a in args where !a.hasPrefix("-") { open(URL(fileURLWithPath: a)) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "=" {
                self?.zoomIn(nil); return nil
            }
            return e
        }
        if let snapshot, let d = documents.last {
            d.snapshotPath = snapshot
            d.window.setFrame(NSRect(x: 40, y: 40, width: 1000, height: 2300), display: true)
        }
    }

    func application(_ sender: NSApplication, open urls: [URL]) { urls.forEach { open($0) } }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { documents.isEmpty }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool { showOpenPanel(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Documents

    func open(_ rawURL: URL, anchor: String? = nil) {
        let url = rawURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { NSSound.beep(); return }
        if let d = documents.first(where: { $0.url == url }) {
            d.window.makeKeyAndOrderFront(nil)
            if let a = anchor { d.scrollTo(anchor: a) }
            activate(); return
        }
        let d = Document(url: url, anchor: anchor)
        documents.append(d)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if documents.count > 1 { cascadePoint = d.window.cascadeTopLeft(from: cascadePoint) }
        else { cascadePoint = d.window.cascadeTopLeft(from: .zero) }
        d.window.makeKeyAndOrderFront(nil)
        activate()
    }

    func documentClosed(_ d: Document) { documents.removeAll { $0 === d } }

    private func activate() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
    }

    func handle(link: URL) {
        guard link.isFileURL else { NSWorkspace.shared.open(link); return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDir) else { NSSound.beep(); return }
        if !isDir.boolValue && mdExtensions.contains(link.pathExtension.lowercased()) {
            open(link, anchor: link.fragment(percentEncoded: false)); return
        }
        if isRunnable(link) { NSWorkspace.shared.activateFileViewerSelecting([link]) }   // reveal, never launch
        else { NSWorkspace.shared.open(link) }
    }

    /// Programs, scripts, bundles, disk images and installer packages are revealed in Finder instead of opened.
    private func isRunnable(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType else { return true }
        var risky: [UTType] = [.executable, .application, .bundle, .diskImage, .shellScript, .appleScript, .osaScript]
        if let pkg = UTType("com.apple.installer-package-archive") { risky.append(pkg) }
        return risky.contains { type.conforms(to: $0) }
    }

    // MARK: Editor hand-off

    func editorURL() -> URL? {
        let fm = FileManager.default
        if let name = Prefs.editorApp, !name.isEmpty {
            if name.hasPrefix("/"), fm.fileExists(atPath: name) { return URL(fileURLWithPath: name) }
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return u }
            for dir in ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications"] {
                let p = "\(dir)/\(name).app"
                if fm.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
            }
        }
        for p in ["/Applications/Visual Studio Code.app", "/Applications/Cursor.app", "/Applications/Zed.app",
                  "/Applications/Sublime Text.app", "/Applications/BBEdit.app", "/Applications/Nova.app",
                  "/System/Applications/TextEdit.app"] where fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return NSWorkspace.shared.urlForApplication(toOpen: .plainText)
    }

    func edit(_ url: URL) {
        guard let app = editorURL() else { NSSound.beep(); return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Actions

    @objc func openDocument(_ sender: Any?) { showOpenPanel() }
    @objc func openRecentItem(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { open(u) } }
    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }
    @objc func setDefaultApp(_ sender: Any?) {
        setAsDefaultHandler { summary in
            let a = NSAlert(); a.messageText = "Default app for Markdown"; a.informativeText = summary; a.runModal()
        }
    }
    @objc func zoomIn(_ sender: Any?) { setZoom(min(3, Prefs.zoom + 0.1)) }
    @objc func zoomOut(_ sender: Any?) { setZoom(max(0.5, Prefs.zoom - 0.1)) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }
    @objc func appearanceSystem(_ sender: Any?) { setAppearance("system") }
    @objc func appearanceLight(_ sender: Any?) { setAppearance("light") }
    @objc func appearanceDark(_ sender: Any?) { setAppearance("dark") }

    private func setZoom(_ z: CGFloat) {
        Prefs.zoom = (z * 10).rounded() / 10
        documents.forEach { $0.webView.pageZoom = Prefs.zoom }
    }
    private func setAppearance(_ a: String) {
        Prefs.appearance = a
        documents.forEach { $0.applyAppearance() }
        for (k, item) in appearanceItems { item.state = (k == a) ? .on : .off }
    }

    func showOpenPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [markdownType, .plainText, .text]
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.message = "Choose a Markdown file to view"
        activate()
        if p.runModal() == .OK { p.urls.forEach { open($0) } }
        else if documents.isEmpty { NSApp.terminate(nil) }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for u in urls {
            let item = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecentItem(_:)), keyEquivalent: "")
            item.representedObject = u
            item.toolTip = u.path
            item.image = NSWorkspace.shared.icon(forFile: u.path); item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if urls.isEmpty { menu.addItem(withTitle: "No Recent Documents", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item === editItem, let app = editorURL() {
            item.title = "Edit in \(FileManager.default.displayName(atPath: app.path))"
        }
        return true
    }

    private func buildMenu() {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let main = NSMenu()

        let appMenu = NSMenu(title: appName)
        appMenu.addItem(item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Make \(appName) the Default for Markdown", #selector(setDefaultApp(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(item("Open…", #selector(openDocument(_:)), "o"))
        let recent = NSMenu(title: "Open Recent"); recent.delegate = self; recentMenu = recent
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item("Reload", #selector(Document.reloadDocument(_:)), "r"))
        file.addItem(.separator())
        let edit = item("Edit in Editor", #selector(Document.editInEditor(_:)), "e"); editItem = edit
        file.addItem(edit)
        file.addItem(item("Reveal in Finder", #selector(Document.revealInFinder(_:)), "r", [.command, .option]))
        file.addItem(item("Copy Path", #selector(Document.copyPath(_:)), "c", [.command, .option]))
        file.addItem(.separator())
        file.addItem(item("Export as PDF…", #selector(Document.exportPDF(_:)), "e", [.command, .shift]))
        file.addItem(item("Print…", #selector(Document.printDocument(_:)), "p"))
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        editMenu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(item("Find…", #selector(Document.findInPage(_:)), "f"))
        editMenu.addItem(item("Find Next", #selector(Document.findNext(_:)), "g"))
        editMenu.addItem(item("Find Previous", #selector(Document.findPrevious(_:)), "g", [.command, .shift]))
        let editMenuItem = NSMenuItem(); editMenuItem.submenu = editMenu; main.addItem(editMenuItem)

        let view = NSMenu(title: "View")
        view.addItem(item("Toggle Outline", #selector(Document.toggleOutline(_:)), "o", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Actual Size", #selector(actualSize(_:)), "0"))
        view.addItem(item("Zoom In", #selector(zoomIn(_:)), "+"))
        view.addItem(item("Zoom Out", #selector(zoomOut(_:)), "-"))
        view.addItem(.separator())
        let appearance = NSMenu(title: "Appearance")
        for (title, key, sel) in [("System", "system", #selector(appearanceSystem(_:))), ("Light", "light", #selector(appearanceLight(_:))), ("Dark", "dark", #selector(appearanceDark(_:)))] {
            let i = item(title, sel, ""); i.state = Prefs.appearance == key ? .on : .off
            appearanceItems[key] = i; appearance.addItem(i)
        }
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: ""); appearanceItem.submenu = appearance
        view.addItem(appearanceItem)
        view.addItem(.separator())
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        let viewItem = NSMenuItem(); viewItem.submenu = view; main.addItem(viewItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

// MARK: - Default-handler registration

func setAsDefaultHandler(completion: @escaping (String) -> Void) {
    let appURL = Bundle.main.bundleURL
    var types = Set<UTType>([markdownType])
    for ext in mdExtensions { if let t = UTType(filenameExtension: ext) { types.insert(t) } }
    let group = DispatchGroup()
    var failures: [String] = []
    for t in types {
        group.enter()
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: t) { err in
            if let err { failures.append("\(t.identifier): \(err.localizedDescription)") }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let now = NSWorkspace.shared.urlForApplication(toOpen: markdownType)?.path ?? "none"
        var s = "Default app for .md is now: \(now)"
        if !failures.isEmpty { s += "\nFailed: " + failures.joined(separator: "; ") }
        completion(s)
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--set-default") {
    setAsDefaultHandler { s in print(s); exit(s.contains("Failed") ? 1 : 0) }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--which") {
    print(NSWorkspace.shared.urlForApplication(toOpen: markdownType)?.path ?? "none"); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.run()
