APP     := dist/HotCopyist.app
BINARY  := .build/release/HotCopyist
VERSION := 1.0.0
DMG     := dist/HotCopyist-$(VERSION).dmg

# Sign with the Developer ID cert when present so the Accessibility grant
# survives rebuilds (TCC keys ad-hoc signatures by cdhash, which changes
# every build — that silently revoked auto-paste after each install).
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"Developer ID Application: [^"]*"' | head -1)
ifeq ($(SIGN_ID),)
SIGN_ID := "-"
endif

.PHONY: app run install dmg clean

# Build a proper .app bundle (recommended: stable path means macOS
# permission grants — Accessibility for auto-paste — stick).
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/HotCopyist
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns; fi
	codesign --force --options runtime --timestamp --sign $(SIGN_ID) $(APP) 2>/dev/null \
		|| codesign --force --sign - $(APP)
	@echo ""
	@echo "✦ Built $(APP)"
	@echo "  Run 'make install' to copy it to /Applications."

# Quick dev loop (permissions won't stick across rebuilds; use 'make app'
# + 'make install' for daily use).
run:
	swift run

install: app
	rm -rf /Applications/HotCopyist.app
	cp -R $(APP) /Applications/HotCopyist.app
	@echo "✦ Installed /Applications/HotCopyist.app — launch it from Spotlight."

# Package the built app into a DMG for direct download. Deliberately does NOT
# depend on `app`: rebuilding would replace the Developer ID signature with an
# ad-hoc one and strip the stapled ticket. Sign + notarize + staple
# dist/HotCopyist.app first (see DISTRIBUTION.md), then run this.
dmg:
	@test -d $(APP) || { echo "✗ $(APP) missing — run 'make app', then sign it"; exit 1; }
	rm -f $(DMG)
	hdiutil create -volname "HotCopyist" -srcfolder $(APP) -ov -format UDZO $(DMG)
	@echo "✦ Built $(DMG)"

clean:
	rm -rf .build dist
