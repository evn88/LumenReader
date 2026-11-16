#!/bin/zsh
# Оформленный DMG (как в PangoZip, scripts/package-dmg.sh): фон с янтарным свечением и стрелкой
# к ярлыку «Программы», иконка тома, фиксированная раскладка окна Finder.
#
#   scripts/make-dmg.sh "build/Lumen Reader.app" build/LumenReader-0.4.dmg
#
# Разметку (.DS_Store, фон, иконку тома) пишет scripts/dmg_layout.py прямо на HFS+ том
# перед сжатием в UDZO. Подпись приложения не меняется: оно копируется через ditto и проверяется.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./product.env
APP="${1:?путь к .app}"
OUT="${2:?путь к .dmg}"
NAME="$(basename "$APP")"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ICON="$APP/Contents/Resources/AppIcon.icns"
[[ -f "$ICON" ]] || { echo "Нет иконки: $ICON" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

mkdir -p "$(dirname "$OUT")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lumen-dmg.XXXXXX")"
MNT="$WORK/mount"; mkdir "$MNT"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

PAYLOAD="$WORK/payload"; mkdir "$PAYLOAD"
ditto "$APP" "$PAYLOAD/$NAME"
ln -s /Applications "$PAYLOAD/Applications"
codesign --verify --deep --strict "$PAYLOAD/$NAME"
python3 scripts/dmg_layout.py prepare-payload "$PAYLOAD" --icon "$ICON" --app-name "$NAME"

# Пишущий HFS+ образ → финальный .DS_Store с CNID тома → сжатие UDZO
hdiutil create -quiet -srcfolder "$PAYLOAD" -fs HFS+ -format UDRW -volname "$PRODUCT_NAME $VER" "$WORK/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MNT" "$WORK/rw.dmg"
mounted=true
python3 scripts/dmg_layout.py finalize-volume "$MNT" --app-name "$NAME"
sync
hdiutil detach -quiet "$MNT" || hdiutil detach -quiet -force "$MNT"
mounted=false
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/final.dmg"
hdiutil verify -quiet "$WORK/final.dmg"

# Проверка содержимого готового образа
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MNT" "$WORK/final.dmg"
mounted=true
[[ -d "$MNT/$NAME" ]] || { echo "В DMG нет $NAME" >&2; exit 1; }
codesign --verify --deep --strict "$MNT/$NAME"
[[ -L "$MNT/Applications" && "$(readlink "$MNT/Applications")" == /Applications ]] || { echo "Нет ссылки Applications" >&2; exit 1; }
for f in .DS_Store .VolumeIcon.icns .background/background.tiff; do
  [[ -f "$MNT/$f" ]] || { echo "В DMG нет $f" >&2; exit 1; }
done
[[ "$(find "$MNT" -mindepth 1 -maxdepth 1 -not -name '.*' | wc -l | tr -d ' ')" == 2 ]] || { echo "Лишние файлы в корне DMG" >&2; exit 1; }
hdiutil detach -quiet "$MNT"
mounted=false
mv -f "$WORK/final.dmg" "$OUT"
echo "DMG: $OUT"
