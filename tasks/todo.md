# WarpHUD — Current Session (2026-04-07)

## Fixes Applied This Session
- [x] Accessibility permission: added `AXIsProcessTrustedWithOptions` prompt + alert + polling on launch
- [x] Tab registration: changed unregistered tab handling to register immediately with "Tab N" placeholder
- [x] Title learning: added `getWarpTitleViaAccessibility()` using AX API (doesn't need Screen Recording)
- [x] Debug logging: added NSLog for tap creation success/failure

## In Progress
- [ ] Verify AX-based title learning works after clear + re-register cycle
- [ ] Title learning for non-current tabs (AX only gets focused window title — need to visit each tab)

## Known Issues
- Codesign on each deploy invalidates accessibility grant — user may need to re-toggle
- `WarpHUDConstants.version`/`.build` referenced by deploy skill but never added to code
- `HUDState.swift:141` — `var name` should be `let name` (compiler warning)

## Backlog
- [ ] Consider stable codesign identity to avoid accessibility re-grant on deploy
- [ ] Add WarpHUDConstants or fix deploy skill version bump
- [ ] Screen Recording permission prompt (optional, for CGWindowList title fallback)
