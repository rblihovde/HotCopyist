APP     := dist/CopyWiz.app
BINARY  := .build/release/CopyWiz

.PHONY: app run install clean

# Build a proper .app bundle (recommended: stable path means macOS
# permission grants — Accessibility for auto-paste — stick).
app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/CopyWiz
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	@echo ""
	@echo "✦ Built $(APP)"
	@echo "  Run 'make install' to copy it to /Applications."

# Quick dev loop (permissions won't stick across rebuilds; use 'make app'
# + 'make install' for daily use).
run:
	swift run

install: app
	rm -rf /Applications/CopyWiz.app
	cp -R $(APP) /Applications/CopyWiz.app
	@echo "✦ Installed /Applications/CopyWiz.app — launch it from Spotlight."

clean:
	rm -rf .build dist
