#!/bin/sh
# mdview installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/PoggyBobby/mdview/main/install.sh | sh
#
# Options (after "sh -s --" when piping):
#   --no-default   install without making mdview the default app for Markdown
#   --uninstall    remove mdview
#
# macOS: builds the native app with the Xcode Command Line Tools and installs /Applications/MDView.app.
# Linux: installs the GTK/WebKitGTK edition under ~/.local (override with MDVIEW_PREFIX).
set -eu

REPO_URL="https://github.com/PoggyBobby/mdview"
TARBALL="$REPO_URL/archive/refs/heads/main.tar.gz"
SET_DEFAULT=1
UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --no-default) SET_DEFAULT=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,12p' "$0" 2>/dev/null || echo "usage: install.sh [--no-default] [--uninstall]"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m%s\033[0m\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

# The checkout that contains this script, or a fresh download of the main branch.
src_dir() {
  d=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
  if [ -n "$d" ] && [ -f "$d/build.sh" ] && [ -f "$d/linux/mdview.py" ]; then
    echo "$d"; return
  fi
  tmp=$(mktemp -d)
  say "Downloading mdview..." >&2
  curl -fsSL "$TARBALL" | tar -xz -C "$tmp"
  echo "$tmp/mdview-main"
}

install_cli_wrapper() {   # $1 = wrapper body
  mkdir -p "$HOME/.local/bin"
  printf '%s\n' "$1" > "$HOME/.local/bin/mdview"
  chmod +x "$HOME/.local/bin/mdview"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) say "Note: add $HOME/.local/bin to your PATH to run 'mdview' from a terminal." ;;
  esac
}

# ------------------------------------------------------------------ macOS
install_macos() {
  if ! xcode-select -p >/dev/null 2>&1; then
    say "mdview needs the Xcode Command Line Tools. Installing them now (a dialog will appear); re-run this installer when they finish."
    xcode-select --install || true
    exit 1
  fi
  SRC=$(src_dir)
  cd "$SRC"
  if [ "$SET_DEFAULT" = 1 ]; then ./build.sh --default; else ./build.sh --install; fi
  install_cli_wrapper '#!/bin/sh
# mdview: open Markdown files in MDView.app (flags go straight to the binary)
case "${1:-}" in
  --*) exec /Applications/MDView.app/Contents/MacOS/MDView "$@" ;;
  "")  exec open -a MDView ;;
  *)   exec open -a MDView "$@" ;;
esac'
  say "Installed /Applications/MDView.app"
}

uninstall_macos() {
  rm -rf /Applications/MDView.app "$HOME/.local/bin/mdview"
  say "Removed /Applications/MDView.app. Pick a new default for .md files in Finder (Get Info > Open With > Change All)."
}

# ------------------------------------------------------------------ Linux
PREFIX=${MDVIEW_PREFIX:-$HOME/.local}
LIB="$PREFIX/share/mdview"
APPS="$PREFIX/share/applications"
ICONS="$PREFIX/share/icons/hicolor"

have_bindings() {
  python3 - <<'PY' >/dev/null 2>&1
import gi
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("WebKit2", "4.1")
except ValueError:
    gi.require_version("WebKit2", "4.0")
from gi.repository import Gtk, WebKit2
PY
}

install_linux_deps() {
  if need python3 && have_bindings; then return; fi
  say "Installing the GTK and WebKitGTK bindings for Python (this needs sudo)..."
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO=sudo
  if need apt-get; then
    $SUDO apt-get update
    $SUDO apt-get install -y python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-webkit2-4.1 xdg-utils \
      || $SUDO apt-get install -y python3 python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-webkit2-4.0 xdg-utils
  elif need dnf; then
    $SUDO dnf install -y python3-gobject python3-cairo gtk3 webkit2gtk4.1 xdg-utils
  elif need pacman; then
    $SUDO pacman -S --needed --noconfirm python-gobject python-cairo gtk3 webkit2gtk-4.1 xdg-utils
  elif need zypper; then
    $SUDO zypper install -y python3-gobject python3-gobject-cairo typelib-1_0-Gtk-3_0 typelib-1_0-WebKit2-4_1 xdg-utils
  elif need apk; then
    $SUDO apk add python3 py3-gobject3 py3-cairo gtk+3.0 webkit2gtk-4.1 xdg-utils
  else
    say "Please install PyGObject with GTK 3 and WebKitGTK 4.1 (or 4.0) using your package manager, then re-run."
    exit 1
  fi
  have_bindings || { say "The WebKitGTK Python bindings are still missing; see the README for package names."; exit 1; }
}

install_linux() {
  install_linux_deps
  SRC=$(src_dir)
  mkdir -p "$LIB" "$APPS" "$ICONS/256x256/apps"
  rm -rf "$LIB/Resources" "$LIB/linux"
  cp -R "$SRC/Resources" "$LIB/Resources"
  cp -R "$SRC/linux" "$LIB/linux"
  cp "$SRC/icon/mdview-256.png" "$ICONS/256x256/apps/mdview.png"
  sed "s|@LIB@|$LIB|g" "$SRC/linux/mdview.desktop" > "$APPS/mdview.desktop"
  install_cli_wrapper "#!/bin/sh
exec python3 \"$LIB/linux/mdview.py\" \"\$@\""
  update-desktop-database "$APPS" 2>/dev/null || true
  gtk-update-icon-cache -q -t "$ICONS" 2>/dev/null || true
  if [ "$SET_DEFAULT" = 1 ] && need xdg-mime; then
    xdg-mime default mdview.desktop text/markdown text/x-markdown 2>/dev/null || true
    say "Default app for text/markdown: $(xdg-mime query default text/markdown 2>/dev/null || echo unknown)"
  fi
  say "Installed mdview to $LIB  (run: mdview file.md)"
}

uninstall_linux() {
  rm -rf "$LIB" "$APPS/mdview.desktop" "$ICONS/256x256/apps/mdview.png" "$HOME/.local/bin/mdview"
  update-desktop-database "$APPS" 2>/dev/null || true
  say "Removed mdview from $PREFIX."
}

# ------------------------------------------------------------------ dispatch
case "$(uname -s)" in
  Darwin) if [ "$UNINSTALL" = 1 ]; then uninstall_macos; else install_macos; fi ;;
  Linux)  if [ "$UNINSTALL" = 1 ]; then uninstall_linux; else install_linux; fi ;;
  *) echo "mdview supports macOS and Linux." >&2; exit 1 ;;
esac
