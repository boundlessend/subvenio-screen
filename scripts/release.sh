#!/usr/bin/env bash
# собирает Release-сборку и пакует её в dist/ образом диска.
# версия берётся из project.yml (MARKETING_VERSION), теги ставятся руками по SemVer:
#   git tag -a v1.0.0 -m "..." && git push origin v1.0.0
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION=$(awk -F'"' '/^ *MARKETING_VERSION:/ {print $2}' project.yml)
if [ -z "$VERSION" ]; then
    echo "MARKETING_VERSION не найден в project.yml" >&2
    exit 1
fi
TAG="v$VERSION"

# версия живёт в трёх местах: project.yml, тег и релиз на GitHub. проверка ловит
# самый частый способ их развести - собрать образ, забыв поднять версию
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "тег $TAG уже существует: подними MARKETING_VERSION в project.yml" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "внимание: рабочее дерево грязное, образ соберётся не из того, что в git" >&2
fi

# именно тот create-dmg, что от sindresorhus: одноимённая формула Homebrew это
# другая утилита с обратным порядком аргументов и без --no-code-sign, и собранный
# ею образ выглядел бы правильным ровно до первого открытия
if ! command -v create-dmg >/dev/null; then
    echo "нужен create-dmg: npm install --global create-dmg" >&2
    exit 1
fi
if ! create-dmg --help 2>&1 | grep -q -- "--no-code-sign"; then
    echo "найден чужой create-dmg: нужен npm-пакет create-dmg (npm install --global create-dmg)" >&2
    exit 1
fi

# то же, что гоняет CI, но до сборки образа, а не после публикации: иначе битый
# встроенный пресет, предупреждение линтера и забытый раздел changelog доезжают до DMG
./scripts/check-changelog.sh
swiftlint lint --strict

xcodegen generate

xcodebuild test \
    -project SubvenioScreen.xcodeproj \
    -scheme SubvenioScreen \
    -destination 'platform=macOS' \
    -derivedDataPath build
# подпись задана здесь, а не взята из Signing.xcconfig: локальный
# Signing.local.xcconfig перекрыл бы её сертификатом этой машины, а сертификат
# уезжает внутрь бинарника вместе с именем и адресом владельца. аргументы
# командной строки сильнее xcconfig, поэтому выпуск всегда ad-hoc, чей бы
# сертификат ни лежал в связке ключей
xcodebuild -project SubvenioScreen.xcodeproj \
    -scheme SubvenioScreen \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

APP="build/Build/Products/Release/Subvenio Screen.app"
if [ ! -d "$APP" ]; then
    echo "сборка не дала $APP" >&2
    exit 1
fi

# приложение не нотаризовано: на чужой машине Gatekeeper потребует ручного
# подтверждения в Privacy & Security. это осознанное решение из PLAN.md
codesign --verify --strict "$APP"

# валидная подпись ещё не значит, что приложение запустится: Library Validation
# из Hardened Runtime отвергала встроенный Pow.framework, и codesign об этом
# молчал. поэтому запуск проверяется на самом деле, а не по подписи.
# запущенная копия сделала бы проверку бессмысленной: вторая копия просит первую
# показать настройки и выходит сама, что не отличить от падения
if pgrep -f "Subvenio Screen.app/Contents/MacOS" >/dev/null; then
    echo "закройте работающую копию: иначе запуск не проверить" >&2
    exit 1
fi
"$APP/Contents/MacOS/Subvenio Screen" &
LAUNCHED=$!
sleep 3
if ! kill -0 "$LAUNCHED" 2>/dev/null; then
    echo "собранное приложение не запускается, смотрите вывод выше" >&2
    exit 1
fi
# TERM, а не KILL: обработчик сигнала возвращает таблицу гаммы на место
kill -TERM "$LAUNCHED"
wait "$LAUNCHED" 2>/dev/null || true
echo "запуск проверен"

mkdir -p dist
rm -f "dist/Subvenio Screen $VERSION.dmg"
# --no-code-sign, потому что сам create-dmg тут не годится: без флага он находит
# в связке ключей первый подходящий сертификат и подписывает им образ, а с
# --identity=- подписывает верно, но потом ищет в выводе codesign строку
# Authority, которой у ad-hoc нет, и выходит с ошибкой на готовом образе
create-dmg --no-code-sign "$APP" dist
DMG="dist/Subvenio Screen $VERSION.dmg"
codesign --sign - "$DMG"
codesign --verify --strict "$DMG"

# ad-hoc подпись без нотаризации ничего не говорит скачавшему о происхождении файла,
# и сумма в тексте релиза это единственный дешёвый способ сверить, тот ли это образ
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

echo "готово: dist/Subvenio Screen $VERSION.dmg"
echo "SHA-256: $SHA"
echo
echo "дальше руками, когда образ проверен:"
echo "  git tag -a $TAG -m \"Subvenio Screen $VERSION\" && git push origin $TAG"
echo "  gh release create $TAG \"dist/Subvenio Screen $VERSION.dmg\" --notes-file <файл>"
echo "  в текст релиза: SHA-256 образа $SHA"
