#!/bin/bash
# Baut ClipBar.app und installiert sie nach ~/Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="ClipBar.app"
swift build -c release

rm -rf "build/$APP"
mkdir -p "build/$APP/Contents/MacOS"
cp .build/release/ClipBar "build/$APP/Contents/MacOS/"
cp Info.plist "build/$APP/Contents/"

# App-Icon: Resources/AppIcon.png (1024px) → AppIcon.icns
mkdir -p "build/$APP/Contents/Resources" build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "build/$APP/Contents/Resources/AppIcon.icns"

# Mit "Apple Development"-Zertifikat signieren, falls vorhanden: dann bleibt die
# Bedienungshilfen-Freigabe (für "Direkt einfügen") auch nach einem Neubau erhalten.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}' || true)
codesign --force --sign "${IDENTITY:--}" "build/$APP"

mkdir -p ~/Applications
pkill -x ClipBar 2>/dev/null || true
sleep 0.5
rm -rf ~/Applications/"$APP"
cp -R "build/$APP" ~/Applications/
open ~/Applications/"$APP"
echo "✅ Installiert: ~/Applications/$APP"
