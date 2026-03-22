#!/bin/bash
# Claude Code session state signal — drives HUD tab colors
# Signals are keyed by TTY (stable per-process), NOT tab number (shifts on close).
# Hammerspoon maps TTY → tab position at render time via .tty files.
#
# Usage: waiting-signal.sh <action>
#   Actions:
#     waiting  — needs user input (red flash)
#     working  — actively processing (green)
#     idle     — finished, no activity (yellow done flash)
ACTION="$1"
HUD_DIR="$HOME/.claude-hud"

# Find our TTY via PID tree walk-up
MY_TTY=""
pid=$$
for _ in 1 2 3 4 5 6 7 8; do
  t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  if [ -n "$t" ] && [ "$t" != "??" ]; then MY_TTY="$t"; break; fi
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$pid" ] && break
done

[ -z "$MY_TTY" ] && exit 0

# Auto-register TTY → tab mapping if missing
# Check if any .tty file already contains our TTY
TTY_REGISTERED=false
for ttyfile in "$HUD_DIR"/*.tty; do
  [ -f "$ttyfile" ] || continue
  if [ "$(cat "$ttyfile" 2>/dev/null)" = "$MY_TTY" ]; then
    TTY_REGISTERED=true
    break
  fi
done

# Self-correcting TTY registration: claim current tab, fix swaps
if [ "$2" = "register" ]; then
  CURRENT=$(cat "$HUD_DIR/current" 2>/dev/null | tr -d ' ')
  if [ -n "$CURRENT" ] && [ -f "$HUD_DIR/$CURRENT" ]; then
    EXISTING_TTY=$(cat "$HUD_DIR/$CURRENT.tty" 2>/dev/null)
    if [ -z "$EXISTING_TTY" ]; then
      # Tab has no TTY — claim it
      echo "$MY_TTY" > "$HUD_DIR/$CURRENT.tty"
    elif [ "$EXISTING_TTY" != "$MY_TTY" ] && [ "$TTY_REGISTERED" = "false" ]; then
      # Tab has a DIFFERENT TTY and we're unregistered — detect swap
      SWAPPED=false
      for i in 1 2 3 4 5 6 7 8 9; do
        if [ "$(cat "$HUD_DIR/$i.tty" 2>/dev/null)" = "$MY_TTY" ]; then
          # Tab $i has our TTY — swap: give $i the existing TTY, take ours
          echo "$EXISTING_TTY" > "$HUD_DIR/$i.tty"
          echo "$MY_TTY" > "$HUD_DIR/$CURRENT.tty"
          SWAPPED=true
          break
        fi
      done
      # If no tab had our TTY, just overwrite (stale mapping)
      if [ "$SWAPPED" = "false" ]; then
        echo "$MY_TTY" > "$HUD_DIR/$CURRENT.tty"
      fi
    elif [ "$EXISTING_TTY" != "$MY_TTY" ] && [ "$TTY_REGISTERED" = "true" ]; then
      # Tab has wrong TTY AND we're registered elsewhere — find and swap
      for i in 1 2 3 4 5 6 7 8 9; do
        if [ "$(cat "$HUD_DIR/$i.tty" 2>/dev/null)" = "$MY_TTY" ]; then
          echo "$EXISTING_TTY" > "$HUD_DIR/$i.tty"
          echo "$MY_TTY" > "$HUD_DIR/$CURRENT.tty"
          break
        fi
      done
    fi
  fi
fi

# Write TTY-keyed signal files (never misrouted — follows the process, not tab position)
case "$ACTION" in
  waiting)
    touch "$HUD_DIR/${MY_TTY}.waiting"
    rm -f "$HUD_DIR/${MY_TTY}.active" "$HUD_DIR/${MY_TTY}.done"
    ;;
  working)
    touch "$HUD_DIR/${MY_TTY}.active"
    rm -f "$HUD_DIR/${MY_TTY}.waiting" "$HUD_DIR/${MY_TTY}.done"
    ;;
  idle)
    rm -f "$HUD_DIR/${MY_TTY}.waiting" "$HUD_DIR/${MY_TTY}.active"
    touch "$HUD_DIR/${MY_TTY}.done"
    ;;
esac
