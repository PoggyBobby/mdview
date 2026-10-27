#!/bin/zsh
# Build MDView.app (with its Quick Look extension).   Usage: ./build.sh [--install] [--default]
#   --install   copy to /Applications and register the app and extension
#   --default   same, then make MDView the default app for Markdown files
set -euo pipefail
cd "$(dirname "$0")"

ARCH=${ARCH:-$(uname -m)}
APP=build/MDView.app
APPEX=$APP/Contents/PlugIns/MDViewQuickLook.appex
DEST=/Applications/MDView.app
FLAGS=(-O -swift-version 5 -target "$ARCH-apple-macosx13.0" -framework AppKit -framework WebKit -framework UniformTypeIdentifiers)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

copy_resources() {   # $1 = destination Resources folder
  cp Resources/viewer.html Resources/app.js "$1/"
  rm -rf "$1/vendor"; cp -R Resources/vendor "$1/vendor"
}

# Application
swiftc "${FLAGS[@]}" -module-name MDView -o "$APP/Contents/MacOS/MDView" Sources/Shared/Core.swift Sources/App/main.swift
cp Info.plist "$APP/Contents/"
copy_resources "$APP/Contents/Resources"
cp icon/MDView.icns "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Quick Look preview extension
swiftc "${FLAGS[@]}" -framework Quartz -parse-as-library -application-extension -module-name MDViewQuickLook \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/MDViewQuickLook" Sources/Shared/Core.swift Sources/QuickLook/PreviewViewController.swift
cp QuickLook/Info.plist "$APPEX/Contents/"
copy_resources "$APPEX/Contents/Resources"

codesign --force --sign - --identifier one.sellab.mdview.quicklook --entitlements QuickLook/MDViewQuickLook.entitlements "$APPEX" 2>&1 | grep -v 'replacing existing' || true
codesign --force --sign - --identifier one.sellab.mdview "$APP" 2>&1 | grep -v 'replacing existing' || true
codesign --verify --deep "$APP"
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
  pkill -x MDView 2>/dev/null || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/MDViewQuickLook.appex" 2>/dev/null || true
  pluginkit -e use -i one.sellab.mdview.quicklook 2>/dev/null || true
  echo "Installed $DEST"
fi
if $setdefault; then
  "$DEST/Contents/MacOS/MDView" --set-default
fi
