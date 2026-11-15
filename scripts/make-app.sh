#!/bin/zsh
# Сборка <PRODUCT_NAME>.app в ~/Applications (название и bundle id — в product.env).
# Подпись: сертификат Apple Development из связки ключей (если есть), иначе ad-hoc.
# Идентификатор бандла и подписи постоянный (com.local.scanreader), поэтому
# разрешения TCC («Полный доступ к диску») сохраняются между сборками.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./product.env

APP="$HOME/Applications/$PRODUCT_NAME.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build -c release

# иконка: PNG 1024 → iconset → icns
swiftc -O scripts/make-icon.swift -o "$WORK/make-icon"
"$WORK/make-icon" "$WORK/icon-1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$WORK/AppIcon.icns"

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScanReader "$APP/Contents/MacOS/$PRODUCT_NAME"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleDisplayName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>SupportURL</key><string>${SUPPORT_URL:-}</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string><string>public.image</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.+)"/\1/' || true)"
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --options runtime --timestamp=none -i "$BUNDLE_ID" -s "$IDENTITY" "$APP"
  echo "Подпись: $IDENTITY"
else
  codesign --force --deep -i "$BUNDLE_ID" -s - "$APP"
  echo "Подпись: ad-hoc"
fi
codesign --verify --strict --verbose=2 "$APP"
echo "Готово: $APP"
