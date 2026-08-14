#!/usr/bin/env bash
# версия живёт в project.yml, а описание изменений в CHANGELOG.md, и разъезжаются
# они молча: образ собирается, релиз выходит, а раздела про эту версию нет.
# проверка ловит это в CI, а не в момент выпуска
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2}' project.yml)
if [ -z "$VERSION" ]; then
    echo "MARKETING_VERSION не найден в project.yml" >&2
    exit 1
fi

if ! grep -q "^## $VERSION\$" CHANGELOG.md; then
    echo "CHANGELOG.md не содержит раздела '## $VERSION'" >&2
    exit 1
fi

echo "версия $VERSION описана в CHANGELOG.md"
