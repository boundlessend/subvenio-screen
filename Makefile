.PHONY: project build run test lint release clean

PROJECT := SubvenioScreen.xcodeproj
SCHEME := SubvenioScreen

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/Subvenio\ Screen.app

test: project
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath build

# та же строгость, что в CI: единственная проверка, которая реально валит сборку,
# должна быть под рукой, а не вспоминаться наизусть
lint:
	swiftlint lint --strict

release: project
	./scripts/release.sh

# dist не трогаем: там лежат собранные образы выпущенных версий,
# и пересобрать их можно только откатившись на соответствующий тег
clean:
	rm -rf build $(PROJECT)
