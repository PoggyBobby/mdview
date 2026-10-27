#!/usr/bin/env python3
"""mdview — a lightweight Markdown viewer. Linux edition: GTK 3 + WebKitGTK.

Shares Resources/ (page template, runtime and vendor libraries) with the macOS app.
Usage: mdview [file.md ...]
       mdview --snapshot OUT file.md   render to OUT (.png, .pdf or .html) and exit
       mdview --set-default            make mdview the default app for text/markdown
       mdview --which                  print the current default app for text/markdown
"""
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
WEBKIT_API = '4.1'
try:
    gi.require_version('WebKit2', '4.1')
except ValueError:
    gi.require_version('WebKit2', '4.0')
    WEBKIT_API = '4.0'
gi.require_version('JavaScriptCore', WEBKIT_API)
from gi.repository import Gdk, Gio, GLib, Gtk, WebKit2  # noqa: E402

APP_ID = 'one.sellab.mdview'
APP_NAME = 'MDView'
DESKTOP_ID = 'mdview.desktop'
SCHEME = 'mdview'
MD_EXT = {'.md', '.markdown', '.mdown', '.mkd', '.mkdn', '.mdwn', '.mdtxt', '.mdtext'}
MARKERS = ('.obsidian', '.git', '.mdview-root')
DEBUG = bool(os.environ.get('MDVIEW_DEBUG'))
CONFIG_DIR = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'mdview'


# ---------------------------------------------------------------- resources

def find_resources():
    env = os.environ.get('MDVIEW_RESOURCES')
    candidates = [Path(env)] if env else []
    here = Path(__file__).resolve().parent
    candidates += [here.parent / 'Resources', here / 'Resources',
                   Path.home() / '.local/share/mdview/Resources',
                   Path('/usr/local/share/mdview/Resources'), Path('/usr/share/mdview/Resources')]
    for c in candidates:
        if (c / 'viewer.html').is_file():
            return c.resolve()
    sys.exit('mdview: cannot find Resources/viewer.html (set MDVIEW_RESOURCES)')


RES = find_resources()
SHELL = (RES / 'viewer.html').read_text(encoding='utf-8')
_m = re.search(r'<style>(.*?)</style>', SHELL, re.S)
PAGE_CSS = _m.group(1) if _m else ''


def escape_html(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;')


def js_string(s):
    return json.dumps(s).replace('</', '<\\/').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')


def base_url(path):
    d = str(Path(path).resolve().parent)
    return f'{SCHEME}://' + quote(d if d.endswith('/') else d + '/')


START_BASE = f'{SCHEME}:///'


def page_html(markdown, path, scroll=0, toc_open=False, recents=None):
    extra = json.dumps({'recents': recents or []}).replace('</', '<\\/')
    classes = []
    if markdown is None:
        classes.append('start')
    elif toc_open:
        classes.append('toc-open')
    html = SHELL.replace('@@NONCE@@', uuid.uuid4().hex)
    html = html.replace('@@BASE@@', escape_html(base_url(path) if path else START_BASE))
    html = html.replace('@@TITLE@@', escape_html(Path(path).name if path else APP_NAME))
    html = html.replace('@@BODYCLASS@@', ' '.join(classes))
    html = html.replace('@@SCROLL@@', str(int(scroll)))
    html = html.replace('@@EXTRA@@', extra)
    return html.replace('@@MD@@', js_string(markdown) if markdown is not None else 'null')


# ---------------------------------------------------------------- roots

class Roots:
    allowed = {}
    _index = {}

    @staticmethod
    def root_for(path):
        d = Path(path).resolve().parent
        home = Path.home().resolve()
        probe = d
        for _ in range(16):
            if any((probe / m).exists() for m in MARKERS):
                return probe
            parent = probe.parent
            if parent == probe or parent == Path('/') or parent == home:
                break
            probe = parent
        return d

    @classmethod
    def allow(cls, root):
        cls.allowed[str(root)] = cls.allowed.get(str(root), 0) + 1

    @classmethod
    def release(cls, root):
        k = str(root)
        if k in cls.allowed:
            cls.allowed[k] -= 1
            if cls.allowed[k] <= 0:
                del cls.allowed[k]

    @classmethod
    def allowed_root(cls, path):
        p = str(path)
        for r in cls.allowed:
            if p == r or p.startswith(r.rstrip('/') + '/'):
                return Path(r)
        return None

    @classmethod
    def resolve(cls, name, root):
        key = str(root)
        built, by_name = cls._index.get(key, (0, None))
        if by_name is None or time.time() - built > 20:
            by_name = {}
            n = 0
            for dirpath, dirnames, filenames in os.walk(root):
                dirnames[:] = [x for x in dirnames if not x.startswith('.')]
                for f in filenames:
                    n += 1
                    if n > 80000:
                        break
                    by_name.setdefault(f.lower(), os.path.join(dirpath, f))
                if n > 80000:
                    break
            cls._index[key] = (time.time(), by_name)
        hit = by_name.get(name.lower())
        return Path(hit) if hit else None

    @classmethod
    def resolve_wikilink(cls, target, from_file):
        t = target.strip()
        if not t:
            return None
        candidates = [t] if Path(t).suffix else [t + '.md', t]
        d = Path(from_file).resolve().parent
        for c in candidates:
            p = (d / c)
            if p.is_file():
                return p.resolve()
        root = cls.root_for(from_file)
        for c in candidates:
            found = cls.resolve(Path(c).name, root)
            if found and ('/' not in c or str(found).lower().endswith('/' + c.lower())):
                return found
        return None


def mime_for(path, trusted):
    ext = Path(path).suffix.lower()
    if not trusted and ext in ('.js', '.mjs', '.html', '.htm', '.xhtml'):
        return 'text/plain; charset=utf-8'
    table = {'.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
             '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.svg': 'image/svg+xml',
             '.woff2': 'font/woff2', '.woff': 'font/woff', '.md': 'text/plain; charset=utf-8', '.txt': 'text/plain; charset=utf-8',
             '.webp': 'image/webp', '.avif': 'image/avif'}
    if ext in table:
        return table[ext]
    return mimetypes.guess_type(str(path))[0] or 'application/octet-stream'


def on_scheme_request(request, *_):
    uri = request.get_uri()
    parts = urlsplit(uri)
    host, path = parts.netloc, unquote(parts.path)
    file = None
    if host == 'app':
        f = (RES / path.lstrip('/')).resolve()
        if str(f).startswith(str(RES) + '/') and f.is_file():
            file = f
    elif host == '':
        f = Path(path).resolve()
        root = Roots.allowed_root(f)
        if root is not None:
            if f.is_file():
                file = f
            else:
                file = Roots.resolve(f.name, root)
    if file is None:
        if DEBUG:
            print('mdview 404', uri, file=sys.stderr)
        stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(b''))
        request.finish(stream, 0, 'text/plain')
        return
    data = file.read_bytes()
    if DEBUG:
        print('mdview 200', uri, len(data), 'bytes', file=sys.stderr)
    stream = Gio.MemoryInputStream.new_from_bytes(GLib.Bytes.new(data))
    request.finish(stream, len(data), mime_for(file, host == 'app'))


# ---------------------------------------------------------------- prefs

class Prefs:
    path = CONFIG_DIR / 'prefs.json'
    data = {}

    @classmethod
    def load(cls):
        try:
            cls.data = json.loads(cls.path.read_text())
        except Exception:
            cls.data = {}

    @classmethod
    def save(cls):
        try:
            cls.path.parent.mkdir(parents=True, exist_ok=True)
            cls.path.write_text(json.dumps(cls.data, indent=1))
        except Exception:
            pass

    @classmethod
    def get(cls, key, default=None):
        return cls.data.get(key, default)

    @classmethod
    def set(cls, key, value):
        cls.data[key] = value
        cls.save()

    @classmethod
    def scroll_for(cls, path):
        return int((cls.data.get('scroll') or {}).get(str(path), [0])[0])

    @classmethod
    def set_scroll(cls, path, y):
        s = cls.data.setdefault('scroll', {})
        s[str(path)] = [int(y), int(time.time())]
        if len(s) > 400:
            for k in sorted(s, key=lambda k: s[k][1])[:len(s) - 300]:
                del s[k]
        cls.save()


# ---------------------------------------------------------------- html export

def katex_css_inlined():
    kdir = RES / 'vendor/katex'
    try:
        css = (kdir / 'katex.min.css').read_text(encoding='utf-8')
    except OSError:
        return ''
    css = re.sub(r',url\(fonts/[^)]+\.(woff|ttf)\) format\("[^"]+"\)', '', css)

    def font(m):
        try:
            import base64
            data = (kdir / 'fonts' / m.group(1)).read_bytes()
            return 'url(data:font/woff2;base64,' + base64.b64encode(data).decode() + ')'
        except OSError:
            return m.group(0)
    return re.sub(r'url\(fonts/([^)]+\.woff2)\)', font, css)


def inline_images(html, path):
    import base64
    d = Path(path).resolve().parent
    root = Roots.root_for(path)

    def repl(m):
        src = m.group(2).replace('&amp;', '&')
        if src.startswith(('data:', 'http:', 'https:')):
            return m.group(0)
        if src.startswith(SCHEME + '://'):
            p = Path(unquote(urlsplit(src).path))
        else:
            p = (d / unquote(src)).resolve()
        if not p.is_file():
            found = Roots.resolve(p.name, root)
            if found:
                p = found
        try:
            data = p.read_bytes()
            if len(data) <= 4 * 1024 * 1024:
                return m.group(1) + 'data:' + mime_for(p, True) + ';base64,' + base64.b64encode(data).decode() + m.group(3)
        except OSError:
            pass
        return m.group(1) + escape_html(p.as_uri()) + m.group(3)
    return re.sub(r'(<img\b[^>]*?\bsrc=")([^"]*)(")', repl, html, flags=re.I)


def standalone_html(title, body, math, path):
    head = ('<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            '<meta name="color-scheme" content="light dark">' + f'<title>{escape_html(title)}</title>')
    if math:
        head += f'<style>{katex_css_inlined()}</style>'
    head += f'<style>{PAGE_CSS}</style>'
    return (f'<!doctype html>\n<html lang="en">\n<head>{head}</head>\n<body>\n<main id="content">\n'
            f'{inline_images(body, path)}\n</main>\n</body>\n</html>\n')


# ---------------------------------------------------------------- appearance

def system_prefers_dark():
    try:
        out = subprocess.run(['gsettings', 'get', 'org.gnome.desktop.interface', 'color-scheme'],
                             capture_output=True, text=True, timeout=2).stdout
        if 'prefer-dark' in out:
            return True
    except Exception:
        pass
    s = Gtk.Settings.get_default()
    return bool(s and (s.props.gtk_application_prefer_dark_theme or 'dark' in (s.props.gtk_theme_name or '').lower()))


def apply_appearance():
    mode = Prefs.get('appearance', 'system')
    dark = system_prefers_dark() if mode == 'system' else mode == 'dark'
    s = Gtk.Settings.get_default()
    if s:
        s.props.gtk_application_prefer_dark_theme = dark


# ---------------------------------------------------------------- window

ERROR_HOOK = """
window.addEventListener('error', e => { try { webkit.messageHandlers.mdv.postMessage({type:'error', message: String(e.message) + ' @ ' + (e.filename||'') + ':' + e.lineno}); } catch (_) {} });
window.addEventListener('unhandledrejection', e => { try { webkit.messageHandlers.mdv.postMessage({type:'error', message: 'unhandled: ' + String(e.reason && e.reason.message || e.reason)}); } catch (_) {} });
"""


class DocumentWindow(Gtk.ApplicationWindow):
    def __init__(self, app, path=None, anchor=None):
        super().__init__(application=app, title=Path(path).name if path else APP_NAME)
        self.app = app
        self.path = Path(path).resolve() if path else None
        self.root = Roots.root_for(self.path) if self.path else None
        self.anchor = anchor
        self.loaded = False
        self.last_content = ''
        self.last_render_ms = -1
        self.exporting = False
        self.snapshot_path = None
        self._refresh_id = None
        self._initial = True
        if self.root:
            Roots.allow(self.root)

        w, h = Prefs.get('window', [900, 760])
        self.set_default_size(int(w), int(h))
        self.header = Gtk.HeaderBar(show_close_button=True, title=self.get_title())
        if self.path:
            self.header.set_subtitle(str(self.path.parent).replace(str(Path.home()), '~'))
        menu_button = Gtk.MenuButton()
        menu_button.set_image(Gtk.Image.new_from_icon_name('open-menu-symbolic', Gtk.IconSize.BUTTON))
        menu_button.set_menu_model(app.menu_model())
        self.header.pack_end(menu_button)
        self.set_titlebar(self.header)

        ucm = WebKit2.UserContentManager()
        ucm.register_script_message_handler('mdv')
        ucm.connect('script-message-received::mdv', self.on_message)
        ucm.add_script(WebKit2.UserScript.new(ERROR_HOOK, WebKit2.UserContentInjectedFrames.TOP_FRAME,
                                              WebKit2.UserScriptInjectionTime.START, None, None))
        self.webview = WebKit2.WebView.new_with_user_content_manager(ucm)
        st = self.webview.get_settings()
        st.set_enable_developer_extras(True)
        st.set_allow_file_access_from_file_urls(False)
        st.set_allow_universal_access_from_file_urls(False)
        st.set_enable_write_console_messages_to_stdout(DEBUG)
        self.webview.set_zoom_level(float(Prefs.get('zoom', 1.0)))
        self.webview.connect('decide-policy', self.on_decide_policy)
        self.webview.connect('load-changed', self.on_load_changed)
        self.webview.connect('create', self.on_create)
        self.add(self.webview)

        for name, cb in [('find', lambda *a: self.js('MDV.find()')), ('find-next', lambda *a: self.js('MDV.findNext()')),
                         ('find-prev', lambda *a: self.js('MDV.findPrev()')), ('outline', lambda *a: self.js('MDV.toggleTOC()')),
                         ('reload', lambda *a: self.refresh(force=True)), ('edit', lambda *a: self.edit()),
                         ('export-html', lambda *a: self.export_html()), ('export-pdf', lambda *a: self.export_pdf()),
                         ('print', lambda *a: self.print_doc()), ('reveal', lambda *a: self.reveal())]:
            action = Gio.SimpleAction.new(name, None)
            action.connect('activate', cb)
            self.add_action(action)

        self.connect('delete-event', self.on_delete)
        self.connect('size-allocate', self.on_size)
        self.load()
        if self.path:
            self.monitor = Gio.File.new_for_path(str(self.path)).monitor_file(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect('changed', self.on_file_changed)
        self.show_all()

    # ----- loading
    def read_markdown(self):
        try:
            return self.path.read_text(encoding='utf-8')
        except UnicodeDecodeError:
            return self.path.read_text(encoding='latin-1')
        except OSError:
            return None

    def load(self):
        self.loaded = False
        self._initial = True
        if self.path:
            md = self.read_markdown()
            if md is None:
                md = f'> **MDView:** could not read `{self.path}`.'
            self.last_content = md
            self.webview.load_html(page_html(md, self.path, Prefs.scroll_for(self.path), Prefs.get('tocOpen', False)), base_url(self.path))
        else:
            self.webview.load_html(page_html(None, None, 0, False, self.app.recent_entries()), START_BASE)

    def refresh(self, force=False):
        if not self.path:
            return
        md = self.read_markdown()
        if md is None:
            self.header.set_title(self.path.name + ' (missing)')
            return
        if not force and md == self.last_content:
            return
        self.last_content = md
        if self.loaded:
            self.js('MDV.render(' + js_string(md) + ')')

    def on_file_changed(self, monitor, f, other, event):
        if self._refresh_id:
            GLib.source_remove(self._refresh_id)
        self._refresh_id = GLib.timeout_add(150, self._do_refresh)

    def _do_refresh(self):
        self._refresh_id = None
        self.refresh()
        return False

    def js(self, code, callback=None):
        if hasattr(self.webview, 'evaluate_javascript'):
            self.webview.evaluate_javascript(code, -1, None, None, None, self._js_done, callback)
        else:
            self.webview.run_javascript(code, None, self._js_done, callback)

    def _js_done(self, webview, result, callback):
        value = None
        try:
            if hasattr(webview, 'evaluate_javascript_finish'):
                value = webview.evaluate_javascript_finish(result)
            else:
                value = webview.run_javascript_finish(result).get_js_value()
        except GLib.Error as e:
            if DEBUG:
                print('js error:', e, file=sys.stderr)
        if callback:
            callback(value)

    # ----- signals
    def on_decide_policy(self, webview, decision, dtype):
        if dtype in (WebKit2.PolicyDecisionType.NAVIGATION_ACTION, WebKit2.PolicyDecisionType.NEW_WINDOW_ACTION):
            action = decision.get_navigation_action()
            uri = action.get_request().get_uri()
            if self._initial and action.get_navigation_type() == WebKit2.NavigationType.OTHER and dtype == WebKit2.PolicyDecisionType.NAVIGATION_ACTION:
                self._initial = False
                decision.use()
                return True
            decision.ignore()
            self.app.handle_link(uri, self)
            return True
        return False

    def on_create(self, webview, action):
        self.app.handle_link(action.get_request().get_uri(), self)
        return None

    def on_load_changed(self, webview, event):
        if event != WebKit2.LoadEvent.FINISHED:
            return
        self.loaded = True
        self._initial = False
        if self.anchor:
            self.js('MDV.scrollToHeading(' + js_string(self.anchor) + ')')
            self.anchor = None
        if self.path:
            md = self.read_markdown()
            if md is not None and md != self.last_content:
                self.last_content = md
                self.refresh(force=True)
        if self.snapshot_path:
            delay = float(os.environ.get('MDVIEW_SNAPSHOT_DELAY', '1.5'))
            GLib.timeout_add(int(delay * 1000), self.take_snapshot)

    def on_message(self, ucm, result):
        try:
            body = json.loads(result.get_js_value().to_json(0))
        except Exception:
            return
        t = body.get('type')
        if t == 'scroll' and self.path and not self.exporting:
            Prefs.set_scroll(self.path, body.get('y', 0))
        elif t == 'toc':
            Prefs.set('tocOpen', bool(body.get('open')))
        elif t == 'wikilink' and self.path:
            target = Roots.resolve_wikilink(body.get('target', ''), self.path)
            if target is None:
                Gdk.beep()
            elif target.suffix.lower() in MD_EXT:
                self.app.open_path(target, body.get('anchor') or None)
            else:
                self.app.handle_link(target.as_uri(), self)
        elif t == 'copy':
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(body.get('text', ''), -1)
        elif t == 'edit':
            self.edit()
        elif t == 'title' and self.path:
            title = (body.get('title') or '').strip() or self.path.name
            self.header.set_title(title)
            self.set_title(title)
        elif t == 'open':
            self.app.open_path(body.get('path', ''))
        elif t == 'openPanel':
            self.app.open_dialog(self)
        elif t == 'rendered':
            self.last_render_ms = int(body.get('ms', -1))
        elif t == 'error' and (DEBUG or self.snapshot_path):
            print('page error:', body.get('message'), file=sys.stderr)

    def on_delete(self, *_):
        if self.root:
            Roots.release(self.root)
        Prefs.save()
        return False

    def on_size(self, widget, alloc):
        if not self.is_maximized():
            Prefs.data['window'] = [alloc.width, alloc.height]

    # ----- actions
    def edit(self):
        if self.path:
            self.app.edit(self.path)

    def reveal(self):
        if self.path:
            Gio.AppInfo.launch_default_for_uri(self.path.parent.as_uri(), None)

    def _save_dialog(self, title, suggested, pattern_name, pattern):
        dialog = Gtk.FileChooserNative.new(title, self, Gtk.FileChooserAction.SAVE, 'Save', 'Cancel')
        dialog.set_do_overwrite_confirmation(True)
        if self.path:
            dialog.set_current_folder(str(self.path.parent))
        dialog.set_current_name(suggested)
        flt = Gtk.FileFilter(); flt.set_name(pattern_name); flt.add_pattern(pattern); dialog.add_filter(flt)
        out = dialog.get_filename() if dialog.run() == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()
        return out

    def export_html(self):
        if not self.path:
            return
        out = self._save_dialog('Export as HTML', self.path.stem + '.html', 'HTML', '*.html')
        if out:
            self.write_html(out)

    def write_html(self, out, done=None):
        def got(value):
            ok = False
            try:
                d = json.loads(value.to_json(0)) if value is not None else None
                if d and d.get('html') is not None:
                    Path(out).write_text(standalone_html(d.get('title') or self.path.name, d['html'], bool(d.get('math')), self.path), encoding='utf-8')
                    ok = True
            except Exception as e:
                print('export failed:', e, file=sys.stderr)
            if done:
                done(ok)
        self.js('MDV.exportData()', got)

    def export_pdf(self):
        if not self.path:
            return
        out = self._save_dialog('Export as PDF', self.path.stem + '.pdf', 'PDF', '*.pdf')
        if out:
            self.write_pdf(out)

    def write_pdf(self, out, done=None):
        op = WebKit2.PrintOperation.new(self.webview)
        ps = Gtk.PrintSettings()
        ps.set_printer('Print to File')
        ps.set(Gtk.PRINT_SETTINGS_OUTPUT_URI, Path(out).resolve().as_uri())
        ps.set(Gtk.PRINT_SETTINGS_OUTPUT_FILE_FORMAT, 'pdf')
        op.set_print_settings(ps)
        setup = Gtk.PageSetup()
        setup.set_top_margin(12, Gtk.Unit.MM); setup.set_bottom_margin(12, Gtk.Unit.MM)
        setup.set_left_margin(12, Gtk.Unit.MM); setup.set_right_margin(12, Gtk.Unit.MM)
        op.set_page_setup(setup)
        self.exporting = True
        if done:
            op.connect('finished', lambda *_: done(Path(out).is_file()))
            op.connect('failed', lambda *_: done(False))
        op.connect('finished', lambda *_: setattr(self, 'exporting', False))
        op.print_()

    def print_doc(self):
        WebKit2.PrintOperation.new(self.webview).run_dialog(self)

    def take_snapshot(self):
        out = self.snapshot_path
        print(f'rendered in {self.last_render_ms} ms')

        def finish(ok, what):
            print(f'{what} written: {out}' if ok else f'{what} failed')
            self.app.quit()
            sys.exit(0 if ok else 1)
        low = out.lower()
        if low.endswith('.pdf'):
            self.write_pdf(out, lambda ok: finish(ok, 'pdf'))
        elif low.endswith('.html'):
            self.write_html(out, lambda ok: finish(ok, 'html'))
        else:
            def cb(webview, res, _):
                try:
                    surface = webview.get_snapshot_finish(res)
                    surface.write_to_png(out)
                    finish(True, 'snapshot')
                except Exception as e:
                    print('snapshot error:', e, file=sys.stderr)
                    finish(False, 'snapshot')
            self.webview.get_snapshot(WebKit2.SnapshotRegion.FULL_DOCUMENT, WebKit2.SnapshotOptions.NONE, None, cb, None)
        return False


# ---------------------------------------------------------------- application

class App(Gtk.Application):
    def __init__(self, snapshot=None):
        flags = Gio.ApplicationFlags.HANDLES_OPEN
        if snapshot:
            flags |= Gio.ApplicationFlags.NON_UNIQUE
        super().__init__(application_id=APP_ID, flags=flags)
        self.snapshot = snapshot
        GLib.set_prgname('mdview')
        GLib.set_application_name(APP_NAME)

    def do_startup(self):
        Gtk.Application.do_startup(self)
        Prefs.load()
        apply_appearance()
        WebKit2.WebContext.get_default().register_uri_scheme(SCHEME, on_scheme_request, None)
        for name, cb in [('open', lambda *a: self.open_dialog(self.get_active_window())), ('new', lambda *a: self.new_window()),
                         ('zoom-in', lambda *a: self.zoom(0.1)), ('zoom-out', lambda *a: self.zoom(-0.1)),
                         ('zoom-reset', lambda *a: self.zoom(None)), ('quit', lambda *a: self.quit())]:
            action = Gio.SimpleAction.new(name, None)
            action.connect('activate', cb)
            self.add_action(action)
        appearance = Gio.SimpleAction.new_stateful('appearance', GLib.VariantType('s'), GLib.Variant('s', Prefs.get('appearance', 'system')))
        appearance.connect('activate', self.on_appearance)
        self.add_action(appearance)
        for action, keys in {'app.open': ['<Primary>o'], 'app.new': ['<Primary>n'], 'app.quit': ['<Primary>q'],
                             'app.zoom-in': ['<Primary>plus', '<Primary>equal', '<Primary>KP_Add'],
                             'app.zoom-out': ['<Primary>minus', '<Primary>KP_Subtract'], 'app.zoom-reset': ['<Primary>0'],
                             'win.find': ['<Primary>f'], 'win.find-next': ['<Primary>g'], 'win.find-prev': ['<Primary><Shift>g'],
                             'win.outline': ['<Primary><Shift>o'], 'win.reload': ['<Primary>r', 'F5'], 'win.edit': ['<Primary>e'],
                             'win.export-html': ['<Primary><Shift>e'], 'win.export-pdf': ['<Primary><Shift>p'],
                             'win.print': ['<Primary>p'], 'win.reveal': ['<Primary><Alt>r']}.items():
            self.set_accels_for_action(action, keys)

    def menu_model(self):
        menu = Gio.Menu()
        s1 = Gio.Menu()
        s1.append('Open…', 'app.open'); s1.append('New Window', 'app.new'); s1.append('Reload', 'win.reload')
        s1.append('Edit in Editor', 'win.edit'); s1.append('Show in Files', 'win.reveal')
        menu.append_section(None, s1)
        s2 = Gio.Menu()
        s2.append('Find…', 'win.find'); s2.append('Toggle Outline', 'win.outline')
        s2.append('Zoom In', 'app.zoom-in'); s2.append('Zoom Out', 'app.zoom-out'); s2.append('Actual Size', 'app.zoom-reset')
        menu.append_section(None, s2)
        s3 = Gio.Menu()
        for label, key in (('System', 'system'), ('Light', 'light'), ('Dark', 'dark')):
            s3.append(label, f'app.appearance::{key}')
        menu.append_submenu('Appearance', s3)
        s4 = Gio.Menu()
        s4.append('Export as HTML…', 'win.export-html'); s4.append('Export as PDF…', 'win.export-pdf'); s4.append('Print…', 'win.print')
        menu.append_section(None, s4)
        s5 = Gio.Menu(); s5.append('Quit', 'app.quit')
        menu.append_section(None, s5)
        return menu

    def on_appearance(self, action, value):
        action.set_state(value)
        Prefs.set('appearance', value.get_string())
        apply_appearance()

    def zoom(self, delta):
        z = 1.0 if delta is None else max(0.5, min(3.0, round(float(Prefs.get('zoom', 1.0)) + delta, 1)))
        Prefs.set('zoom', z)
        for w in self.get_windows():
            if isinstance(w, DocumentWindow):
                w.webview.set_zoom_level(z)

    def do_activate(self):
        if not self.get_windows():
            self.new_window()

    def do_open(self, files, n, hint):
        for f in files:
            self.open_path(f.get_path())

    def new_window(self):
        w = DocumentWindow(self)
        if self.snapshot:
            w.snapshot_path = self.snapshot
        w.present()
        return w

    def documents(self):
        return [w for w in self.get_windows() if isinstance(w, DocumentWindow)]

    def open_path(self, path, anchor=None):
        p = Path(path).expanduser()
        if not p.is_file():
            Gdk.beep()
            return
        p = p.resolve()
        for w in self.documents():
            if w.path == p:
                w.present()
                if anchor:
                    w.js('MDV.scrollToHeading(' + js_string(anchor) + ')')
                return
        try:
            Gtk.RecentManager.get_default().add_item(p.as_uri())
        except Exception:
            pass
        w = DocumentWindow(self, p, anchor)
        if self.snapshot:
            w.snapshot_path = self.snapshot
            w.resize(1000, 2300)
        start = next((d for d in self.documents() if d.path is None), None)
        w.present()
        if start is not None:
            start.destroy()

    def recent_entries(self):
        try:
            items = [i for i in Gtk.RecentManager.get_default().get_items()
                     if i.get_uri().startswith('file://') and Path(unquote(urlsplit(i.get_uri()).path)).suffix.lower() in MD_EXT]
        except Exception:
            return []
        items.sort(key=lambda i: i.get_modified(), reverse=True)
        out = []
        for i in items[:12]:
            p = Path(unquote(urlsplit(i.get_uri()).path))
            if p.is_file():
                out.append({'name': p.name, 'dir': str(p.parent).replace(str(Path.home()), '~'), 'path': str(p)})
        return out

    def open_dialog(self, parent):
        dialog = Gtk.FileChooserNative.new('Open Markdown', parent, Gtk.FileChooserAction.OPEN, 'Open', 'Cancel')
        dialog.set_select_multiple(True)
        flt = Gtk.FileFilter(); flt.set_name('Markdown'); [flt.add_pattern('*' + e) for e in MD_EXT]; dialog.add_filter(flt)
        if dialog.run() == Gtk.ResponseType.ACCEPT:
            for f in dialog.get_filenames():
                self.open_path(f)
        dialog.destroy()

    def handle_link(self, uri, window):
        parts = urlsplit(uri)
        if parts.scheme in ('file', SCHEME) and not parts.netloc:
            p = Path(unquote(parts.path))
            if not p.exists():
                Gdk.beep()
                return
            if p.is_file() and p.suffix.lower() in MD_EXT:
                self.open_path(p, unquote(parts.fragment) or None)
                return
            if p.is_file() and os.access(p, os.X_OK):      # never launch programs from a document link
                Gio.AppInfo.launch_default_for_uri(p.parent.as_uri(), None)
                return
            Gio.AppInfo.launch_default_for_uri(p.as_uri(), None)
            return
        if parts.scheme in ('http', 'https', 'mailto', 'tel'):
            Gio.AppInfo.launch_default_for_uri(uri, None)

    def edit(self, path):
        cmd = Prefs.get('editor') or os.environ.get('MDVIEW_EDITOR')
        if cmd:
            subprocess.Popen(cmd.split() + [str(path)])
            return
        try:
            desktop = subprocess.run(['xdg-mime', 'query', 'default', 'text/plain'], capture_output=True, text=True, timeout=3).stdout.strip()
        except Exception:
            desktop = ''
        if desktop and desktop != DESKTOP_ID and shutil.which('gtk-launch'):
            subprocess.Popen(['gtk-launch', desktop, str(path)])
        elif os.environ.get('VISUAL') or os.environ.get('EDITOR'):
            subprocess.Popen((os.environ.get('VISUAL') or os.environ.get('EDITOR')).split() + [str(path)])
        else:
            Gdk.beep()


# ---------------------------------------------------------------- entry point

def main(argv):
    args = argv[1:]
    if '--help' in args or '-h' in args:
        print(__doc__.strip())
        return 0
    if '--which' in args:
        print(subprocess.run(['xdg-mime', 'query', 'default', 'text/markdown'], capture_output=True, text=True).stdout.strip() or 'none')
        return 0
    if '--set-default' in args:
        for mime in ('text/markdown', 'text/x-markdown'):
            subprocess.run(['xdg-mime', 'default', DESKTOP_ID, mime], check=False)
        print('Default app for text/markdown is now:', subprocess.run(['xdg-mime', 'query', 'default', 'text/markdown'], capture_output=True, text=True).stdout.strip())
        return 0
    snapshot = None
    if '--snapshot' in args:
        i = args.index('--snapshot')
        if i + 1 >= len(args):
            sys.exit('--snapshot needs an output path')
        snapshot = str(Path(args[i + 1]).resolve())
        del args[i:i + 2]
    files = [str(Path(a).resolve()) for a in args if not a.startswith('-')]
    app = App(snapshot)
    return app.run([argv[0]] + files)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
