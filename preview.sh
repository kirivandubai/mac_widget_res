#!/bin/bash
# Отрисовывает панель в PNG (светлая и тёмная темы), не запуская приложение в строке меню.
# Удобно для правки вёрстки: ./preview.sh [папка назначения]
set -euo pipefail
cd "$(dirname "$0")"

OUTPUT="${1:-build}"
mkdir -p "$OUTPUT" build

SOURCES=()
for file in Sources/*.swift; do
  [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done

swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -o build/render "${SOURCES[@]}" Tools/Preview/main.swift

./build/render "$OUTPUT"
