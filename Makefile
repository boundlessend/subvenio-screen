.PHONY: project build run test release clean

PROJECT := ScreenFilter.xcodeproj
SCHEME := ScreenFilter

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/ScreenFilter.app

test: project
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath build

release: project
	./scripts/release.sh

clean:
	rm -rf build dist $(PROJECT)
