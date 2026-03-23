# WarpHUD

A native macOS overlay that shows your Claude Code sessions as color-coded tab cards, anchored to your Warp terminal window.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 5.10](https://img.shields.io/badge/Swift-5.10-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## What it does

When you run multiple Claude Code sessions in Warp tabs, WarpHUD gives you a persistent at-a-glance view of every session's state:

- **Amber (breathing)** — Claude is working
- **Green** — Idle, waiting for your next prompt
- **Red (flashing)** — Needs your input
- **Cyan (flashing)** — Task completed

Cards show the tab number, project folder, and session name. Click any card to switch to that tab instantly.

## Features

- **Zero config** — install and forget, works automatically with Claude Code hooks
- **Native Swift/SwiftUI** — lightweight background app, no Electron, no Hammerspoon
- **Traffic-light states** — instantly see which sessions need attention
- **Click to switch** — click a card to jump to that Warp tab
- **Cmd+digit detection** — HUD tracks your tab switches in real time
- **Hover tooltips** — see the full session name on hover
- **Active tab indicator** — optional floating indicator for the current session
- **Draggable** — pin or drag the HUD anywhere on screen
- **Settings panel** — toggle tooltips, resource monitor, indicator, quit-with-Warp
- **CPU/memory stats** — optional system resource display
- **Auto-hide** — only visible when Warp is focused
- **Auto-launch** — starts at login via LaunchAgent
- **Single instance** — won't spawn duplicates

## Requirements

- macOS 14 (Sonoma) or later
- [Warp terminal](https://www.warp.dev/)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with hooks configured
- Swift 5.10+ (Xcode Command Line Tools)

## Install

```bash
git clone https://github.com/mertkalak/warp-hud.git
cd warp-hud
./setup.sh
```

This builds a release binary, packages `WarpHUD.app`, installs it to `/Applications`, and sets up a LaunchAgent for auto-start.

### Manual build

```bash
swift build          # debug
swift build -c release  # release
make run             # build + launch .app bundle
make install         # build + install to /Applications + LaunchAgent
```

## Uninstall

```bash
./setup.sh uninstall
```

Or: `make uninstall`

## How it works

WarpHUD reads session state files from `~/.claude-hud/`, written by Claude Code's shell hooks:

```
~/.claude-hud/
├── 1              # Session name for tab 1
├── 1.tty          # TTY identifier (e.g., ttys004)
├── ttys004.active  # Exists = Claude is working
├── ttys004.waiting # Exists = needs user input
├── ttys004.done    # Exists = task completed
├── ttys004.cwd     # Working directory path
└── current         # Currently active tab number
```

The shell scripts in `scripts/` are the data layer — they write these files. WarpHUD is the UI layer — it reads them and renders the overlay.

### Setting up the hooks

Add these to your Claude Code hooks configuration (`~/.claude/settings.json`):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/warp-hud/scripts/waiting-signal.sh working"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/warp-hud/scripts/waiting-signal.sh working"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/warp-hud/scripts/waiting-signal.sh waiting"
          }
        ]
      }
    ]
  }
}
```

For CWD tracking in Zsh, add to your `.zshrc`:

```bash
source /path/to/warp-hud/scripts/zshenv
```

For Bash, add to your `.bashrc`:

```bash
export BASH_ENV="/path/to/warp-hud/scripts/bash_cwd_capture.sh"
```

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+1-9 | Switch tabs (detected by WarpHUD) |
| Cmd+Ctrl+R | Reload WarpHUD |
| Cmd+Ctrl+W | Clear all sessions |

## Architecture

```
WarpHUD/
├── App/WarpHUDApp.swift        # @main, lifecycle, hotkeys
├── Models/
│   ├── Session.swift           # Tab session data model
│   └── HUDState.swift          # @Observable single source of truth
├── Services/
│   ├── AppWatcher.swift        # NSWorkspace focus tracking
│   ├── KeyboardTap.swift       # CGEvent tap for Cmd+digit
│   ├── StatsMonitor.swift      # CPU/memory monitoring
│   └── WarpWindow.swift        # Warp window geometry
└── Views/
    ├── HUDPanel.swift          # NSPanel (floating, non-activating)
    ├── HUDView.swift           # Main SwiftUI view
    ├── TabCard.swift           # Individual session card
    ├── TooltipPanel/View.swift # Hover tooltip
    ├── ActiveTabPanel/View.swift # Floating current-tab indicator
    ├── SettingsPanel/View.swift # Settings popover
    ├── StatsView.swift         # CPU/memory display
    └── PinButton.swift         # Pin/unpin toggle
```

**Design:** SwiftUI renders the cards, `@Observable` HUDState is the single source of truth, file polling reads `~/.claude-hud/` every 250ms. No private APIs — uses `CGWindowListCopyWindowInfo` for Warp window geometry.

## Contributing

PRs welcome. The codebase is straightforward Swift/SwiftUI — no Xcode project needed, just `swift build`.

## License

MIT
