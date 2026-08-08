#!/usr/bin/env bash
# собирает Release-сборку и пакует её в dist/ образом диска.
# версия берётся из project.yml (MARKETING_VERSION), теги ставятся руками по SemVer:
#   git tag -a v1.0.0 -m "..." && git push origin v1.0.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(awk -F'"' '/MARKETING_VERSION/ {print $2}' project.yml)
if [ -z "$VERSION" ]; then
    echo "MARKETING_VERSION не найден в project.yml" >&2
    exit 1
fi

if ! command -v create-dmg >/dev/null; then
    echo "нужен create-dmg: brew install create-dmg" >&2
    exit 1
fi

xcodegen generate
xcodebuild -project ScreenFilter.xcodeproj \
    -scheme ScreenFilter \
    -configuration Release \
    -derivedDataPath build \
    build

APP=build/Build/Products/Release/ScreenFilter.app
if [ ! -d "$APP" ]; then
    echo "сборка не дала $APP" >&2
    exit 1
fi

# приложение не нотаризовано: на чужой машине Gatekeeper потребует ручного
# подтверждения в Privacy & Security. это осознанное решение из PLAN.md
codesign --verify --strict "$APP"

mkdir -p dist
rm -f "dist/ScreenFilter $VERSION.dmg"
create-dmg "$APP" dist

echo "готово: dist/ScreenFilter $VERSION.dmg"
