#!/bin/bash
# Сборка ResBar.app без Xcode: только swiftc из Command Line Tools.
#
#   ./build.sh            — собрать в build/ResBar.app
#   ./build.sh --install  — собрать, установить в /Applications и запустить
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ResBar"
DEPLOYMENT_TARGET="14.0"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

echo "==> Сборка $APP_NAME для $ARCH (macOS $DEPLOYMENT_TARGET+)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

swiftc \
  -O -swift-version 5 \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Иконка рисуется скриптом, чтобы не хранить бинарные файлы в репозитории.
if [ -f Tools/MakeIcon.swift ]; then
  echo "==> Иконка"
  swift Tools/MakeIcon.swift "$APP_BUNDLE/Contents/Resources/AppIcon.icns" || \
    echo "    иконку создать не удалось, продолжаю без неё"
fi

# Подпись «для себя»: без неё macOS не даёт приложению закрепиться в строке меню.
echo "==> Подпись"
codesign --force --sign - --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1

echo "==> Готово: $APP_BUNDLE"

if [ "${1:-}" = "--install" ]; then
  echo "==> Установка в /Applications"
  # Приложение живёт в строке меню без поддержки Apple Events, поэтому одного
  # «quit app» мало: без принудительного завершения open увидит запущенный
  # экземпляр и оставит работать старую сборку.
  osascript -e 'quit app "ResBar"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Запущено. Значок появится в строке меню слева от часов."
fi
