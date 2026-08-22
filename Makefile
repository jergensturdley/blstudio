# BlStudio — macOS client for the bl (Bailian) CLI
#
# Targets:
#   make build     — compile (release)
#   make universal — compile universal (arm64 + x86_64) release binary
#   make app       — build + bundle dist/BlStudio.app
#   make bundle    — bundle dist/BlStudio.app from an existing $(BIN) (no rebuild)
#   make run       — build app bundle and launch it
#   make dev       — swift run (debug, no bundling)
#   make test      — run tests (needs full Xcode for XCTest) or fall back to selftest
#   make selftest  — headless smoke tests against the real bl binary
#   make zip       — bundle + ad-hoc sign + dist/BlStudio-macos.zip
#   make icon      — regenerate the app icon
#   make clean     — remove build artifacts
#
# Works with Apple's GNU Make 3.81 (the default `make` on macOS and on
# GitHub's macOS runners).

ARCH     := $(shell uname -m)
SCRATCH  ?= .build
CONFIG   ?= release
# Override BIN to bundle a pre-built binary (CI passes the universal product).
BIN      ?= $(SCRATCH)/$(ARCH)-apple-macosx/$(CONFIG)/BlStudio
# Universal (lipo'd) product path.
UBIN      = $(SCRATCH)/universal/BlStudio
APP       = dist/BlStudio.app
VERSION  ?= dev
# Extra flags for swift build in restricted environments (e.g. --disable-sandbox).
SWIFT_FLAGS ?=

.PHONY: build universal app bundle run dev test selftest zip codesign icon clean

build:
	swift build -c $(CONFIG) --scratch-path $(SCRATCH) $(SWIFT_FLAGS)

universal:
	swift build -c release --scratch-path $(SCRATCH) --arch arm64 $(SWIFT_FLAGS)
	swift build -c release --scratch-path $(SCRATCH) --arch x86_64 $(SWIFT_FLAGS)
	mkdir -p "$(SCRATCH)/universal"
	lipo -create \
		"$(SCRATCH)/arm64-apple-macosx/release/BlStudio" \
		"$(SCRATCH)/x86_64-apple-macosx/release/BlStudio" \
		-output "$(UBIN)"
	@echo "Universal binary at $(UBIN)"

app: build bundle

bundle: icon
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/BlStudio"
	if [ -f dist/AppIcon.icns ]; then cp dist/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; fi
	sed "s/__VERSION__/$(VERSION)/" Tools/Info.plist > "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@echo "Bundled $(APP)"

run: app
	open "$(APP)"

dev:
	swift run $(SWIFT_FLAGS)

test:
	swift test --scratch-path $(SCRATCH) $(SWIFT_FLAGS) || make selftest

selftest: build
	"$(BIN)" --selftest
	"$(BIN)" --viewprobe

codesign:
	codesign --force --sign - --options runtime "$(APP)"
	@echo "Ad-hoc signed $(APP)"

zip: universal
	$(MAKE) bundle BIN="$(UBIN)" VERSION="$(VERSION)"
	$(MAKE) codesign
	rm -f dist/BlStudio-macos.zip
	cd dist && ditto -c -k --sequesterRsrc --keepParent BlStudio.app BlStudio-macos.zip
	@echo "Created dist/BlStudio-macos.zip"

icon:
	@if [ ! -f dist/AppIcon.icns ]; then $(MAKE) dist/AppIcon.icns; fi

dist/AppIcon.icns: Tools/make_icon.swift
	mkdir -p dist
	swift Tools/make_icon.swift dist/icon_1024.png
	rm -rf /tmp/blstudio.iconset
	mkdir -p /tmp/blstudio.iconset
	sips -z 16 16     dist/icon_1024.png --out /tmp/blstudio.iconset/icon_16x16.png      >/dev/null
	sips -z 32 32     dist/icon_1024.png --out /tmp/blstudio.iconset/icon_16x16@2x.png   >/dev/null
	sips -z 32 32     dist/icon_1024.png --out /tmp/blstudio.iconset/icon_32x32.png      >/dev/null
	sips -z 64 64     dist/icon_1024.png --out /tmp/blstudio.iconset/icon_32x32@2x.png   >/dev/null
	sips -z 128 128   dist/icon_1024.png --out /tmp/blstudio.iconset/icon_128x128.png    >/dev/null
	sips -z 256 256   dist/icon_1024.png --out /tmp/blstudio.iconset/icon_128x128@2x.png >/dev/null
	sips -z 256 256   dist/icon_1024.png --out /tmp/blstudio.iconset/icon_256x256.png    >/dev/null
	sips -z 512 512   dist/icon_1024.png --out /tmp/blstudio.iconset/icon_256x256@2x.png >/dev/null
	sips -z 512 512   dist/icon_1024.png --out /tmp/blstudio.iconset/icon_512x512.png    >/dev/null
	sips --resampleWidth 1024 dist/icon_1024.png --out /tmp/blstudio.iconset/icon_512x512@2x.png >/dev/null
	for f in /tmp/blstudio.iconset/*.png; do \
		sips -s dpiWidth 72 -s dpiHeight 72 "$$f" >/dev/null; \
	done
	for attempt in 1 2 3; do \
		if iconutil -c icns /tmp/blstudio.iconset -o dist/AppIcon.icns; then break; fi; \
		echo "iconutil attempt $$attempt failed, retrying…"; sleep 1; \
	done
	@if [ ! -f dist/AppIcon.icns ]; then \
		echo "warning: could not build AppIcon.icns; bundling without an icon"; fi

clean:
	rm -rf "$(SCRATCH)" dist
