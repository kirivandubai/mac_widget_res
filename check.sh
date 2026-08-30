#!/bin/bash
# Самопроверка: сверяет метрики с показаниями top и прогоняет разбор данных.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
SOURCES=()
for file in Sources/*.swift; do
  [ "$(basename "$file")" = "main.swift" ] || SOURCES+=("$file")
done

swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -o build/selfcheck "${SOURCES[@]}" Tools/SelfCheck/main.swift

./build/selfcheck
