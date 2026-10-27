#!/bin/zsh
# Build MDView.app.   Usage: ./build.sh [--install] [--default]
#   --install   copy to /Applications and register it with Launch Services
#   --default   same, then make MDView the default app for Markdown files
set -euo pipefail
cd "$(dirname "$0")"

ARCH=${ARCH:-$(uname -m)}          # arm64 or x86_64
APP=build/MDView.app
DEST=/Applications/MDView.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/vendor"
swiftc -O -swift-version 5 -target "$ARCH-apple-macosx13.0" \
  -framework AppKit -framework WebKit -framework UniformTypeIdentifiers \
  -o "$APP/Contents/MacOS/MDView" Sources/main.swift
cp Info.plist "$APP/Contents/"
cp Resources/viewer.html Resources/app.js "$APP/Contents/Resources/"
cp Resources/vendor/* "$APP/Contents/Resources/vendor/"
cp icon/MDView.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - --identifier one.sellab.mdview "$APP"
echo "Built $APP"

install=false; setdefault=false
for arg in "$@"; do
  case "$arg" in
    --install) install=true ;;
    --default) install=true; setdefault=true ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if $install; then
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  echo "Installed $DEST"
fi
if $setdefault; then
  "$DEST/Contents/MacOS/MDView" --set-default
fi
