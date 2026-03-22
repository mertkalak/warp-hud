# Warp HUD — Native Swift/SwiftUI Rewrite

## Context
Replace the Hammerspoon dependency with a standalone native macOS app. The shell scripts (waiting-signal.sh, bash_cwd_capture.sh, zshenv, notify.sh) stay as the data layer. The Swift app replaces Hammerspoon as the UI/event layer.

The existing `init.lua` (1,711 lines) is the Hammerspoon implementation — use it as the definitive reference for behavior, layout, colors, and logic. Every feature in init.lua should eventually be replicated in Swift.

## Architecture

### What Hammerspoon provides today (to replace)
| Feature | Hammerspoon | Swift equivalent |
|---|---|---|
| Window overlay | hs.canvas | NSPanel (non-activating, floating, transparent) |
| Keyboard events | hs.eventtap | CGEvent tap (requires Accessibility permission) |
| App focus | hs.application.watcher | NSWorkspace.didActivateApplication notification |
| File watching | hs.pathwatcher | DispatchSource / FSEvents |
| Timers | hs.timer | Timer / DispatchSourceTimer |
| Async shell | hs.task | Process (Foundation) |
| Space detection | hs.spaces | CGSCopySpaces (private API) or NSWorkspace |
| Hotkeys | hs.hotkey | MASShortcut / Carbon RegisterEventHotKey |
| Styled text | hs.styledtext | SwiftUI Text with modifiers |
| Window geometry | hs.window | AXUIElement or CGWindowListCopyWindowInfo |

### App type
**LSUIElement = true** (no dock icon, no menu bar unless wanted). Background agent app with a floating panel.

### Data layer (existing shell scripts — DO NOT MODIFY)
- `scripts/waiting-signal.sh` — TTY registration + signal state (working/waiting/idle). Called by Claude Code hooks.
- `scripts/bash_cwd_capture.sh` — Bash CWD capture via BASH_ENV EXIT trap
- `scripts/notify.sh` — macOS notification helper
- `scripts/zshenv` — Zsh CWD capture via EXIT trap
- Runtime state directory: `~/.claude-hud/` with files like `1` (session name), `1.tty`, `1.lock`, `ttys001.active`, `ttys001.cwd`, `current`

### Session file format (in `~/.claude-hud/`)
| File | Content | Example |
|---|---|---|
| `N` | Session name (one line) | `⠐ fix-hammerspoon-tab-label-mismatch` |
| `N.tty` | TTY string | `ttys004` |
| `N.lock` | Empty file = name is locked | (exists or not) |
| `N.nick` | Nickname | `Skye` |
| `N.avatar` | Avatar type | `designer` |
| `N.pos` | Card position JSON | `{"x": 804.6, "y": 492.3}` |
| `current` | Current tab number | `3` |
| `TTY.active` | Empty = Claude is working | (exists or not) |
| `TTY.waiting` | Empty = needs user input | (exists or not) |
| `TTY.done` | Empty = task completed | (exists or not) |
| `TTY.cwd` | Working directory path | `/Users/mertkalak/GitHub/dentacost` |

### Project structure
```
warp-hud/
├── WarpHUD/
│   ├── App/
│   │   └── WarpHUDApp.swift       # @main, app lifecycle
│   ├── Views/
│   │   ├── HUDPanel.swift         # NSPanel subclass (floating, non-activating)
│   │   ├── HUDView.swift          # Main SwiftUI view (horizontal card strip)
│   │   └── TabCard.swift          # Single tab card (number, folder, name, state)
│   ├── Models/
│   │   ├── Session.swift          # Tab session data model
│   │   └── HUDState.swift         # @Observable, single source of truth
│   ├── Services/
│   │   ├── FileWatcher.swift      # Watch ~/.claude-hud/ for changes
│   │   ├── KeyboardTap.swift      # CGEvent tap for Cmd+digit, Cmd+T/W
│   │   ├── AppWatcher.swift       # NSWorkspace focus tracking (show/hide HUD)
│   │   ├── CWDResolver.swift      # lsof + .cwd file reading
│   │   └── WarpWindow.swift       # Track Warp window position/size
│   └── Utilities/
│       └── ShellTask.swift        # Async shell command runner
├── scripts/                        # Existing shell scripts (data layer)
│   ├── waiting-signal.sh
│   ├── bash_cwd_capture.sh
│   ├── notify.sh
│   └── zshenv
├── init.lua                        # REFERENCE ONLY — Hammerspoon implementation
├── setup.sh                        # Installer
├── README.md
├── CLAUDE.md                       # This file
└── Package.swift
```

### Key design decisions
1. **SwiftUI for rendering** — `.animation(.easeInOut)` replaces 100+ lines of manual Lua animation
2. **@Observable pattern** — HUDState is the single source of truth, FileWatcher updates it, SwiftUI re-renders
3. **No private APIs** — CGWindowListCopyWindowInfo for window geometry
4. **Swift Package Manager** — No Xcode project, just Package.swift
5. **Reference init.lua** for exact colors, sizes, and behavior

### Colors (from init.lua)
```
Traffic lights (border/text):
  Working:  amber   (r=1.0, g=0.8, b=0.2)
  Idle:     green   (r=0.3, g=0.9, b=0.4)
  Done:     cyan    (r=0.3, g=0.85, b=0.95)
  Waiting:  red     (r=1.0, g=0.3, b=0.3)
  Hover:    orange  (r=1.0, g=0.6, b=0.2)

Card backgrounds (translucent):
  Working:  warm dark amber (r=0.18, g=0.16, b=0.08, a=0.6)
  Idle:     dark green      (r=0.06, g=0.16, b=0.08, a=0.55)
  Done:     dark cyan       (r=0.08, g=0.14, b=0.18, a=0.55)
  Waiting:  dark red        (r=0.28, g=0.08, b=0.08, a=0.7)

HUD background: black at 0.85 alpha
Folder text: (r=0.65, g=0.65, b=0.72, a=0.9)
```

### Layout (from init.lua)
```
HUD anchored to bottom-right of Warp window
  Right margin: 200px from right edge
  Bottom offset: 62px from bottom
  Card height: 38px (two lines: folder + session name)
  Card padding: 10px horizontal, 3px vertical
  Card gap: 5px
  Card corner radius: 4px
  Max name length: 10 chars (truncated)
  Font: Menlo 11px (name), Menlo 10px (folder)
```

## Phase plan
| Phase | What |
|---|---|
| 1 | Basic overlay: read session files, show cards with traffic-light colors, anchor to Warp window |
| 2 | File watcher: auto-update on ~/.claude-hud/ changes |
| 3 | Keyboard tap: Cmd+digit detection, currentTab tracking |
| 4 | Interactive: hover highlight, click-to-switch tabs |
| 5 | CWD detection: lsof + .cwd reading, folder name display |
| 6 | Animations: breathing borders, flashing states |
| 7 | Window tracking: follow Warp window move/resize |
| 8 | Setup script + README + distribution |

## Phase 1 spec — Basic overlay

Create a buildable Swift app that:
1. Reads `~/.claude-hud/` session files (1-9, N.tty, TTY.active/waiting/done, TTY.cwd, current)
2. Renders a horizontal strip of tab cards at the bottom-right of the Warp window
3. Each card shows: tab number, folder name (from CWD), session name (truncated)
4. Card background color reflects state (working=amber, idle=green, done=cyan, waiting=red)
5. Current tab has a highlighted border
6. HUD only visible when Warp is the focused app
7. NSPanel with `.floating` level, non-activating, transparent background

Build: `swift build` → run the binary.

## Verification
- `swift build` succeeds
- Running the binary shows the overlay over Warp
- Cards reflect current session state from ~/.claude-hud/
- HUD hides when switching to another app
