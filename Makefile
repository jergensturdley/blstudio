# BlStudio — macOS client for the bl (Bailian) CLI
#
# Targets:
#   make build    — compile (release)
#   make app      — build + bundle dist/BlStudio.app
#   make run      — build app bundle and launch it
#   make dev      — swift run (debug, no bundling)
#   make test     — run tests (needs full Xcode for XCTest) or fall back to selftest
#   make selftest — headless smoke tests against the real bl binary
#   make icon     — regenerate the app icon
#   make clean    — remove build artifacts

ARCH     := $(shell uname -m)
SCRATCH  ?= .build
CONFIG   ?= release
BIN      := $(SCRATCH)/$(ARCH)-apple-macosx/$(CONFIG)/BlStudio
APP      := dist/BlStudio.app
# Extra flags for swift build in restricted environments (e.g. --disable-sandbox).
SWIFT_FLAGS ?=

.PHONY: build app run dev test selftest icon clean

build:
	swift build -c $(CONFIG) --scratch-path $(SCRATCH) $(SWIFT_FLAGS)

app: build icon
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/BlStudio"
	if [ -f dist/AppIcon.icns ]; then cp dist/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; fi
	sed "s/__VERSION__/$$(date +%Y.%m.%d)/" Tools/Info.plist > "$(APP)/Contents/Info.plist"
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
