# WarpHUD — Current Session (2026-04-07)

## Fixes Applied This Session
- [x] Accessibility permission: added `AXIsProcessTrustedWithOptions` prompt + alert + polling on launch
- [x] Tab registration: register immediately with "Tab N", verify via title change after 300ms
- [x] Title learning: added `getWarpTitleViaAccessibility()` using AX API (no Screen Recording needed)
- [x] Click-through: only consume mouse clicks when HUD panel is visible (`hudVisible` flag)
- [x] Panel hide: consolidated into `hidePanel()` method
- [x] Phantom tab fix: preserve `current` through clear, treat nil previousTab as unknown
- [x] Status prefix stripping: compare titles without ⠐/✳ prefixes to avoid false positives
- [x] Committed and pushed: `eb9f1bb` and `f3e47a2`

## Known Issues
- Codesign on each deploy invalidates accessibility grant — user may need to re-toggle
- `WarpHUDConstants.version`/`.build` referenced by deploy skill but never added to code
- `HUDState.swift:141` — `var name` should be `let name` (compiler warning)
- Rapid tab cycling (Cmd+3 → Cmd+4 within ~50ms) may still cause a false positive if Warp is mid-switch when titleBefore is captured

## Backlog
- [ ] Consider stable codesign identity to avoid accessibility re-grant on deploy
- [ ] Add WarpHUDConstants or fix deploy skill version bump
- [ ] Fix `var name` → `let name` warning in HUDState.swift
