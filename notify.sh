#!/bin/bash
# Claude Code notification helper — includes HUD tab context
# Usage: notify.sh <title> <message> <sound>
# Example: notify.sh "Claude Code" "Task completed" "Glass"

TITLE="$1"
MESSAGE="$2"
SOUND="${3:-default}"

TAB_NUM=""
TAB_NAME=""

# Method 1: env var (set by cs() for new sessions)
if [ -n "$CLAUDE_HUD_TAB" ]; then
  TAB_NUM="$CLAUDE_HUD_TAB"
  TAB_NAME=$(cat "$HOME/.claude-hud/$TAB_NUM" 2>/dev/null)
fi

# Method 2: walk PID tree to find TTY, then match against .tty files
if [ -z "$TAB_NUM" ]; then
  MY_TTY=""
  pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "??" ]; then
      MY_TTY="$t"
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
  done

  if [ -n "$MY_TTY" ]; then
    for ttyfile in "$HOME/.claude-hud"/*.tty; do
      [ -f "$ttyfile" ] || continue
      if [ "$(cat "$ttyfile" 2>/dev/null)" = "$MY_TTY" ]; then
        TAB_NUM=$(basename "$ttyfile" .tty)
        TAB_NAME=$(cat "$HOME/.claude-hud/$TAB_NUM" 2>/dev/null)
        break
      fi
    done
  fi
fi

# Append tab context to title
if [ -n "$TAB_NUM" ]; then
  if [ -n "$TAB_NAME" ]; then
    TITLE="$TITLE [Tab $TAB_NUM: $TAB_NAME]"
  else
    TITLE="$TITLE [Tab $TAB_NUM]"
  fi
fi

terminal-notifier -title "$TITLE" -message "$MESSAGE" -sound "$SOUND"

# AgentHUD: write notification to .notify file for speech bubbles
if [ -n "$TAB_NUM" ]; then
  echo "info:${MESSAGE}" >> "$HOME/.claude-hud/${TAB_NUM}.notify"
fi
