.PHONY: project build run test release clean

PROJECT := SubvenireScreen.xcodeproj
SCHEME := SubvenireScreen

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath build build

run: build
	open build/Build/Products/Debug/Subvenire\ Screen.app

test: project
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' -derivedDataPath build

release: project
	./scripts/release.sh

clean:
	rm -rf build dist $(PROJECT)
