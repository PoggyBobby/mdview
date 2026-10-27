import Foundation
import WebKit
import UniformTypeIdentifiers

// Shared between the app and the Quick Look extension.

let mdExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext"]
let markdownType = UTType("net.daringfireball.markdown") ?? .plainText
let schemeName = "mdview"

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - Document roots: which folders a page may read from

enum Roots {
    private static let markers = [".obsidian", ".git", ".mdview-root"]

    /// Nearest ancestor containing a vault/project marker, stopping below the home folder; else the file's own folder.
    static func root(for file: URL) -> URL {
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent().standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var probe = dir
        for _ in 0..<16 {
            if markers.contains(where: { fm.fileExists(atPath: probe.appendingPathComponent($0).path) }) { return probe }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path || parent.path == "/" || parent.path == home { break }
            probe = parent
        }
        return dir
    }

    private static var allowed: [String: Int] = [:]     // root path -> number of open documents using it
    static func allow(_ root: URL) { allowed[root.standardizedFileURL.path, default: 0] += 1 }
    static func release(_ root: URL) {
        let k = root.standardizedFileURL.path
        if let c = allowed[k] { if c <= 1 { allowed[k] = nil } else { allowed[k] = c - 1 } }
    }
    static func allowedRoot(containing path: String) -> URL? {
        for r in allowed.keys where path == r || path.hasPrefix(r.hasSuffix("/") ? r : r + "/") { return URL(fileURLWithPath: r) }
        return nil
    }

    private static var indexes: [String: (built: Date, byName: [String: String])] = [:]
    /// First regular file named `name` (case-insensitive) anywhere under `root`; the index is cached briefly.
    static func resolve(name: String, in root: URL) -> URL? {
        let key = root.standardizedFileURL.path
        if let ix = indexes[key], Date().timeIntervalSince(ix.built) < 20 {
            return ix.byName[name.lowercased()].map { URL(fileURLWithPath: $0) }
        }
        var byName: [String: String] = [:]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            var n = 0
            for case let f as URL in en {
                n += 1; if n > 80_000 { break }
                let k = f.lastPathComponent.lowercased()
                if byName[k] == nil, (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { byName[k] = f.path }
            }
        }
        indexes[key] = (Date(), byName)
        return byName[name.lowercased()].map { URL(fileURLWithPath: $0) }
    }

    /// Obsidian-style link target: relative to the file's folder first, then by name anywhere in the root.
    static func resolveWikilink(_ target: String, from file: URL) -> URL? {
        let fm = FileManager.default
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let candidates = (t as NSString).pathExtension.isEmpty ? [t + ".md", t] : [t]
        let dir = file.deletingLastPathComponent()
        for c in candidates {
            let u = dir.appendingPathComponent(c).standardizedFileURL
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
        }
        let r = root(for: file)
        for c in candidates {
            if let found = resolve(name: (c as NSString).lastPathComponent, in: r) {
                if !c.contains("/") || found.path.lowercased().hasSuffix("/" + c.lowercased()) { return found }
            }
        }
        return nil
    }
}

// MARK: - mdview:// scheme

/// mdview://app/<path>   -> files inside the bundle's Resources folder (page runtime, vendor libraries, fonts)
/// mdview:///<abs path>  -> files inside an allowed document root; a missing path falls back to a file of that name in the root
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = SchemeHandler()
    static let debug = ProcessInfo.processInfo.environment["MDVIEW_DEBUG"] != nil
    static let resources: URL = (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).standardizedFileURL

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let host = url.host ?? ""
        var file: URL?
        if host == "app" {
            let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            let f = SchemeHandler.resources.appendingPathComponent(rel).standardizedFileURL
            if f.path.hasPrefix(SchemeHandler.resources.path + "/") { file = f }
        } else if host.isEmpty {
            let f = URL(fileURLWithPath: url.path).standardizedFileURL
            if Roots.allowedRoot(containing: f.path) != nil {
                if FileManager.default.fileExists(atPath: f.path) { file = f }
                else if let root = Roots.allowedRoot(containing: f.path), let found = Roots.resolve(name: f.lastPathComponent, in: root) { file = found }
            }
        }
        guard let f = file, let data = FileManager.default.contents(atPath: f.path) else {
            if SchemeHandler.debug { fputs("mdview 404 \(url.absoluteString)\n", stderr) }
            respond(task, status: 404, data: Data(), mime: "text/plain"); return
        }
        if SchemeHandler.debug { fputs("mdview 200 \(url.absoluteString) (\(data.count) bytes)\n", stderr) }
        respond(task, status: 200, data: data, mime: SchemeHandler.mimeType(for: f, trusted: host == "app"))
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, status: Int, data: Data, mime: String) {
        guard let url = task.request.url,
              let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-cache", "Access-Control-Allow-Origin": "*"]) else { return }
        task.didReceive(resp)
        if !data.isEmpty { task.didReceive(data) }
        task.didFinish()
    }

    static func mimeType(for file: URL, trusted: Bool) -> String {
        let ext = file.pathExtension.lowercased()
        if !trusted, ["js", "mjs", "html", "htm", "xhtml"].contains(ext) { return "text/plain; charset=utf-8" }
        switch ext {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "md", "markdown", "txt": return "text/plain; charset=utf-8"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

// MARK: - Page template

enum Template {
    static let shell: String = (try? String(contentsOf: SchemeHandler.resources.appendingPathComponent("viewer.html"), encoding: .utf8)) ?? ""
    static let css: String = {
        guard let a = shell.range(of: "<style>"), let b = shell.range(of: "</style>") else { return "" }
        return String(shell[a.upperBound..<b.lowerBound])
    }()

    /// A JavaScript string literal safe inside a <script> block (JSONSerialization escapes "/", so "</script>" cannot occur).
    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]) else { return "\"\"" }
        var json = String(decoding: data, as: UTF8.self)
        json.removeFirst(); json.removeLast()
        return json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    static func encodedPath(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
    static let startBase = URL(string: "\(schemeName):///")!
    static func baseURL(for file: URL) -> URL {
        let dir = file.deletingLastPathComponent().standardizedFileURL.path
        return URL(string: "\(schemeName)://" + encodedPath(dir.hasSuffix("/") ? dir : dir + "/")) ?? startBase
    }

    /// markdown == nil renders the start page (recents: [[name, dir, path]]).
    static func html(markdown: String?, fileURL: URL?, scrollY: Int, tocOpen: Bool, recents: [[String: String]] = []) -> String {
        let extra = (try? JSONSerialization.data(withJSONObject: ["recents": recents])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var classes: [String] = []
        if markdown == nil { classes.append("start") }
        if tocOpen && markdown != nil { classes.append("toc-open") }
        return shell
            .replacingOccurrences(of: "@@NONCE@@", with: UUID().uuidString)
            .replacingOccurrences(of: "@@BASE@@", with: escapeHTML(fileURL.map { baseURL(for: $0).absoluteString } ?? startBase.absoluteString))
            .replacingOccurrences(of: "@@TITLE@@", with: escapeHTML(fileURL?.lastPathComponent ?? "MDView"))
            .replacingOccurrences(of: "@@BODYCLASS@@", with: classes.joined(separator: " "))
            .replacingOccurrences(of: "@@SCROLL@@", with: String(scrollY))
            .replacingOccurrences(of: "@@EXTRA@@", with: extra.replacingOccurrences(of: "</", with: "<\\/"))
            .replacingOccurrences(of: "@@MD@@", with: markdown.map(jsString) ?? "null")
    }
}

// MARK: - Standalone HTML export

enum HTMLExport {
    static let inlineImageLimit = 4 * 1024 * 1024

    static func standalone(title: String, body: String, math: Bool, fileURL: URL) -> String {
        var head = "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><meta name=\"color-scheme\" content=\"light dark\">"
        head += "<title>\(escapeHTML(title))</title>"
        if math { head += "<style>\(katexCSS())</style>" }
        head += "<style>\(Template.css)</style>"
        let content = inlineImages(in: body, fileURL: fileURL)
        return "<!doctype html>\n<html lang=\"en\">\n<head>\(head)</head>\n<body>\n<main id=\"content\">\n\(content)\n</main>\n</body>\n</html>\n"
    }

    /// katex.min.css with its woff2 fonts embedded as data URIs (woff/ttf fallbacks dropped).
    static func katexCSS() -> String {
        let dir = SchemeHandler.resources.appendingPathComponent("vendor/katex")
        guard var css = try? String(contentsOf: dir.appendingPathComponent("katex.min.css"), encoding: .utf8) else { return "" }
        css = css.replacingOccurrences(of: #",url\(fonts/[^)]+\.(woff|ttf)\) format\("[^"]+"\)"#, with: "", options: .regularExpression)
        let re = try! NSRegularExpression(pattern: #"url\(fonts/([^)]+\.woff2)\)"#)
        var out = ""; var last = css.startIndex
        for m in re.matches(in: css, range: NSRange(css.startIndex..., in: css)) {
            guard let r = Range(m.range, in: css), let nr = Range(m.range(at: 1), in: css) else { continue }
            out += css[last..<r.lowerBound]
            let name = String(css[nr])
            if let data = try? Data(contentsOf: dir.appendingPathComponent("fonts/" + name)) {
                out += "url(data:font/woff2;base64,\(data.base64EncodedString()))"
            } else { out += css[r] }
            last = r.upperBound
        }
        out += css[last...]
        return out
    }

    /// Rewrites <img src> values to data URIs (small files) or absolute file URLs.
    static func inlineImages(in html: String, fileURL: URL) -> String {
        let re = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc=")([^"]*)(")"#, options: .caseInsensitive)
        let dir = fileURL.deletingLastPathComponent()
        let root = Roots.root(for: fileURL)
        var out = ""; var last = html.startIndex
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let whole = Range(m.range, in: html), let pre = Range(m.range(at: 1), in: html),
                  let srcR = Range(m.range(at: 2), in: html), let post = Range(m.range(at: 3), in: html) else { continue }
            out += html[last..<whole.lowerBound]
            let src = String(html[srcR]).replacingOccurrences(of: "&amp;", with: "&")
            var replacement = src
            if !src.hasPrefix("data:"), !src.hasPrefix("http:"), !src.hasPrefix("https:") {
                var path = src
                if path.hasPrefix("\(schemeName)://") { path = URL(string: src)?.path ?? src }
                else if let u = URL(string: src, relativeTo: dir), u.isFileURL { path = u.standardizedFileURL.path }
                else { path = dir.appendingPathComponent(src).standardizedFileURL.path }
                var file = URL(fileURLWithPath: path.removingPercentEncoding ?? path)
                if !FileManager.default.fileExists(atPath: file.path), let found = Roots.resolve(name: file.lastPathComponent, in: root) { file = found }
                if let data = try? Data(contentsOf: file), data.count <= inlineImageLimit {
                    replacement = "data:\(SchemeHandler.mimeType(for: file, trusted: true));base64,\(data.base64EncodedString())"
                } else { replacement = file.absoluteString }
            }
            out += html[pre] + escapeHTML(replacement) + html[post]
            last = whole.upperBound
        }
        out += html[last...]
        return out
    }
}
