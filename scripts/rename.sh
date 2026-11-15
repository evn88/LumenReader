#!/bin/zsh
# Переименование продукта одной командой: scripts/rename.sh "NewName" [com.example.newname]
# Меняет product.env, запасное имя в Product.swift и заголовки README. Модуль Swift (ScanReader) не трогает.
set -euo pipefail
cd "$(dirname "$0")/.."
NEW="$1"; ID="${2:-com.local.$(echo "$NEW" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')}"
source ./product.env
OLD="$PRODUCT_NAME"
sed -i '' "s/^PRODUCT_NAME=.*/PRODUCT_NAME=\"$NEW\"/; s/^BUNDLE_ID=.*/BUNDLE_ID=\"$ID\"/" product.env
sed -i '' "s/fallbackName = \"$OLD\"/fallbackName = \"$NEW\"/" Sources/ScanReader/Product.swift
for f in README.md README.ru.md; do [[ -f $f ]] && sed -i '' "s/$OLD/$NEW/g" $f; done
echo "Готово: $OLD → $NEW ($ID). Пересоберите: scripts/make-app.sh"
