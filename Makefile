export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Sign with your Apple Development certificate when you have one: macOS ties the Accessibility
# permission to the signature, and an ad-hoc one changes with every build, so each rebuild would ask again.
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development[^"]*"')
SIGNING := $(if $(IDENTITY),CODE_SIGN_IDENTITY=$(IDENTITY) CODE_SIGN_STYLE=Manual)

run: build
	-osascript -e 'tell application id "dev.alexis.Hypermeme" to quit' 2>/dev/null
	while lsappinfo find bundleid=dev.alexis.Hypermeme | grep -q ASN; do sleep 0.2; done
	open -n build/Build/Products/Debug/Hypermeme.app

build:
	xcodegen generate -q
	xcodebuild -project Hypermeme.xcodeproj -scheme Hypermeme -derivedDataPath build -quiet build $(SIGNING)

test:
	xcodegen generate -q
	xcodebuild -project Hypermeme.xcodeproj -scheme Hypermeme -derivedDataPath build -quiet test

dmg:
	scripts/build-dmg.sh

.PHONY: run build test dmg
