#!/bin/zsh
# Подготовка релиза (как в PangoZip, локально): сборка → подпись → DMG → подписанная лента Sparkle.
# Ничего не публикует: в конце печатает команду `gh release create` — её запускает человек.
#
#   scripts/release.sh 0.2            # версия; номер сборки — число коммитов
#
# Приватный EdDSA-ключ берётся из Keychain (аккаунт = BUNDLE_ID из product.env, создан
# `generate_keys --account <BUNDLE_ID>`) или из переменной SPARKLE_PRIVATE_KEY (CI-секрет).
set -euo pipefail
cd "$(dirname "$0")/.."
source ./product.env
VER="${1:?укажите версию, например: scripts/release.sh 0.2}"
TAG="v$VER"
REPO="${RELEASE_REPO:-evn88/LumenReader}"
BUILD_DIR="$PWD/build"
SLUG="${PRODUCT_NAME// /}"
DMG="$BUILD_DIR/$SLUG-$VER.dmg"
TOOLS=.build/artifacts/sparkle/Sparkle/bin

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"
swift test
VERSION="$VER" BUILD_NUMBER="$(git rev-list --count HEAD)" APP_DIR="$BUILD_DIR" ./scripts/make-app.sh

# DMG как в PangoZip: фон со свечением и стрелкой, иконка тома, раскладка окна Finder
./scripts/make-dmg.sh "$BUILD_DIR/$PRODUCT_NAME.app" "$DMG"
shasum -a 256 "$DMG" | sed "s|$BUILD_DIR/||" > "$DMG.sha256"

# Лента обновлений: одна версия, подписи архива и всей ленты
FEED="$BUILD_DIR/feed"; mkdir -p "$FEED"; cp "$DMG" "$FEED/"
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then KEY=(--ed-key-file -); else KEY=(--account "$BUNDLE_ID"); fi
print -rn -- "${SPARKLE_PRIVATE_KEY:-}" | "$TOOLS/generate_appcast" "${KEY[@]}" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases/tag/$TAG" --maximum-deltas 0 --maximum-versions 1 "$FEED"
# минимальная версия macOS — в ленту (Sparkle не предложит обновление на старой системе)
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUILD_DIR/$PRODUCT_NAME.app/Contents/Info.plist")"
python3 - "$FEED/appcast.xml" "$MIN_OS" <<'PY'
import sys, re
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
if "sparkle:minimumSystemVersion" not in s:
    s = s.replace("</sparkle:shortVersionString>", "</sparkle:shortVersionString>\n            <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>" % v, 1)
open(p, "w").write(s)
PY
cp "$FEED/appcast.xml" "$BUILD_DIR/appcast.xml"
print -rn -- "${SPARKLE_PRIVATE_KEY:-}" | "$TOOLS/sign_update" "${KEY[@]}" "$BUILD_DIR/appcast.xml"
print -rn -- "${SPARKLE_PRIVATE_KEY:-}" | "$TOOLS/sign_update" "${KEY[@]}" --verify "$BUILD_DIR/appcast.xml"
rm -rf "$FEED"

cat <<MSG

Готово: $DMG
         $BUILD_DIR/appcast.xml (подписана)
Публикация (запускает человек):

  gh release create $TAG --repo $REPO --title "$PRODUCT_NAME $VER" --generate-notes \\
    "$DMG" "$DMG.sha256" "$BUILD_DIR/appcast.xml"

Лента в приложении: $UPDATE_FEED_URL
MSG
