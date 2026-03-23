#!/bin/bash
# WarpHUD — one-command install
# Usage: ./setup.sh [install|uninstall]
set -e

ACTION="${1:-install}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WarpHUD"
BUNDLE="$APP_NAME.app"
INSTALL_DIR="/Applications"
AGENT_PLIST="com.warphud.app.plist"
AGENTS_DIR="$HOME/Library/LaunchAgents"

case "$ACTION" in
  install)
    echo "=== WarpHUD Installer ==="
    echo ""

    # Check Swift
    if ! command -v swift &>/dev/null; then
      echo "✗ Swift not found. Install Xcode or Command Line Tools:"
      echo "  xcode-select --install"
      exit 1
    fi

    # Build
    echo "→ Building release binary..."
    cd "$REPO_DIR"
    swift build -c release 2>&1 | tail -1
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

    # Package .app
    echo "→ Creating $BUNDLE..."
    rm -rf "$REPO_DIR/$BUNDLE"
    mkdir -p "$REPO_DIR/$BUNDLE/Contents/MacOS"
    cp "$BIN_PATH" "$REPO_DIR/$BUNDLE/Contents/MacOS/"
    cp "$REPO_DIR/Resources/Info.plist" "$REPO_DIR/$BUNDLE/Contents/"

    # Install
    echo "→ Installing to $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR/$BUNDLE"
    cp -r "$REPO_DIR/$BUNDLE" "$INSTALL_DIR/"

    # LaunchAgent
    echo "→ Setting up auto-launch..."
    mkdir -p "$AGENTS_DIR"
    cp "$REPO_DIR/Resources/$AGENT_PLIST" "$AGENTS_DIR/"
    launchctl bootout "gui/$(id -u)" "$AGENTS_DIR/$AGENT_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS_DIR/$AGENT_PLIST"

    echo ""
    echo "✓ WarpHUD installed and running!"
    echo "  • Starts automatically at login"
    echo "  • Shows over Warp when focused"
    echo "  • Gear icon → settings"
    echo "  • To uninstall: ./setup.sh uninstall"
    ;;

  uninstall)
    echo "=== WarpHUD Uninstaller ==="
    echo ""
    echo "→ Stopping WarpHUD..."
    launchctl bootout "gui/$(id -u)" "$AGENTS_DIR/$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENTS_DIR/$AGENT_PLIST"
    echo "→ Removing app..."
    rm -rf "$INSTALL_DIR/$BUNDLE"
    rm -rf "$REPO_DIR/$BUNDLE"
    echo ""
    echo "✓ WarpHUD uninstalled"
    ;;

  *)
    echo "Usage: ./setup.sh [install|uninstall]"
    exit 1
    ;;
esac
