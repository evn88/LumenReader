#!/bin/zsh
# Сборка <PRODUCT_NAME>.app в ~/Applications (название и bundle id — в product.env).
# Подпись: сертификат Apple Development из связки ключей (если есть), иначе ad-hoc.
# Идентификатор бандла и подписи постоянный (com.local.scanreader), поэтому
# разрешения TCC («Полный доступ к диску») сохраняются между сборками.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./product.env

# APP_DIR — куда собрать (по умолчанию ~/Applications; scripts/release.sh собирает в build/)
APP="${APP_DIR:-$HOME/Applications}/$PRODUCT_NAME.app"
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

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScanReader "$APP/Contents/MacOS/$PRODUCT_NAME"
cp "$WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# фирменный акцент (AccentColor): выделение в списках, кнопки, переключатели — янтарь вместо синего
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --output-partial-info-plist "$WORK/assets.plist" >/dev/null
# Sparkle (автообновление) — во Frameworks, как в PangoZip
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework \
  "$APP/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt"
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
  <key>CFBundleVersion</key><string>${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleLocalizations</key><array><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.books</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>SupportURL</key><string>${SUPPORT_URL:-}</string>
  <key>SiteURL</key><string>${SITE_URL:-}</string>
  <key>SUFeedURL</key><string>${UPDATE_FEED_URL:-}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY:-}</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><false/>
  <key>SUAllowsAutomaticUpdates</key><false/>
  <key>SUEnableSystemProfiling</key><false/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
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
SIGN="${IDENTITY:--}"
RUNTIME=(); [[ "$SIGN" != "-" ]] && RUNTIME=(--options runtime --timestamp=none)
# Sparkle — своими идентификаторами (без -i), затем само приложение
codesign --force --deep "${RUNTIME[@]}" -s "$SIGN" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${RUNTIME[@]}" -i "$BUNDLE_ID" -s "$SIGN" "$APP"
echo "Подпись: ${IDENTITY:-ad-hoc}"
codesign --verify --strict --verbose=2 "$APP"
echo "Готово: $APP"
