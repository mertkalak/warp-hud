# WarpHUD — Lessons Learned

## 2026-04-07: Silent permission failures

**Problem:** CGEvent tap fails silently when accessibility permission is missing. App runs but does nothing visible.

**Root cause:** `CGEvent.tapCreate()` returns `nil` without any error — the app continued without key handling.

**Fix:** Check `AXIsProcessTrusted()` on launch, show alert, poll for grant.

**Rule:** Never silently swallow permission failures. Always provide user-facing feedback when a critical capability is unavailable.

---

## 2026-04-07: Codesign invalidates TCC grants

**Problem:** Each `/deploy` re-codesigns the app, which invalidates the macOS accessibility permission.

**Root cause:** macOS ties TCC (Transparency, Consent, Control) grants to the app's code signature hash. `codesign --force` changes the hash.

**Fix:** The accessibility check on launch catches this, but it's still a UX friction point.

**Rule:** Be aware that any codesign change resets TCC permissions. Consider ad-hoc or stable signing.

---

## 2026-04-07: kCGWindowName requires Screen Recording

**Problem:** `CGWindowListCopyWindowInfo` with `kCGWindowName` returns nil for window titles without Screen Recording permission.

**Root cause:** macOS separates Accessibility (UI element inspection) from Screen Recording (window content/titles via CGWindowList).

**Fix:** Use `AXUIElement` with `kAXTitleAttribute` instead — works with Accessibility permission alone.

**Rule:** For reading window titles, prefer AX API over CGWindowList. Only use CGWindowList for geometry (bounds, layer, owner name — these don't need Screen Recording).

---

## 2026-04-07: Tab registration must not depend on title change

**Problem:** Unregistered tabs weren't registered when Cmd+digit was pressed because the code waited for the Warp title to change as "proof" the tab exists.

**Root cause:** If already on the target tab or if Warp is slow to update, the title doesn't change within the 200ms window. The code assumed "no title change = tab doesn't exist" and reverted.

**Fix:** Register immediately with "Tab N", then poll for a meaningful title in the background.

**Rule:** Prefer optimistic registration with lazy enrichment over pessimistic validation for user-initiated actions.
