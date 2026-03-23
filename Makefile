APP_NAME     = WarpHUD
BUNDLE       = $(APP_NAME).app
INSTALL_DIR  = /Applications
AGENT_PLIST  = com.warphud.app.plist
AGENTS_DIR   = $(HOME)/Library/LaunchAgents

.PHONY: build install uninstall clean run

build:
	swift build -c release
	@echo "→ Packaging $(BUNDLE)..."
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(BUNDLE)/Contents/MacOS/
	cp Resources/Info.plist $(BUNDLE)/Contents/
	codesign --force --sign - $(BUNDLE)
	@echo "✓ $(BUNDLE) ready (signed)"

install: build
	@echo "→ Installing to $(INSTALL_DIR)..."
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	cp -r $(BUNDLE) $(INSTALL_DIR)/
	@echo "→ Setting up launch agent..."
	mkdir -p $(AGENTS_DIR)
	cp Resources/$(AGENT_PLIST) $(AGENTS_DIR)/
	launchctl bootout gui/$$(id -u) $(AGENTS_DIR)/$(AGENT_PLIST) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENTS_DIR)/$(AGENT_PLIST)
	@echo "✓ Installed and running. WarpHUD starts automatically at login."

uninstall:
	@echo "→ Stopping WarpHUD..."
	launchctl bootout gui/$$(id -u) $(AGENTS_DIR)/$(AGENT_PLIST) 2>/dev/null || true
	rm -f $(AGENTS_DIR)/$(AGENT_PLIST)
	rm -rf $(INSTALL_DIR)/$(BUNDLE)
	rm -rf $(BUNDLE)
	@echo "✓ Uninstalled"

clean:
	swift package clean
	rm -rf $(BUNDLE)

run: build
	open $(BUNDLE)
