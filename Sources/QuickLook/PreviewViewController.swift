import Cocoa
import Quartz
import WebKit

/// Quick Look preview extension: renders Markdown with the same page runtime as the app.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: WKWebView!

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler.shared, forURLScheme: schemeName)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .windowBackgroundColor
        view = webView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let md = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        Roots.allow(Roots.root(for: url))
        webView.loadHTMLString(Template.html(markdown: md, fileURL: url, scrollY: 0, tocOpen: false), baseURL: Template.baseURL(for: url))
        handler(nil)
    }
}
