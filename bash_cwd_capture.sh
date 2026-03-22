#!/bin/bash
# Capture Claude Bash sandbox CWD for HUD folder display.
# Sourced via BASH_ENV. Uses EXIT trap to capture CWD after sandbox cd + commands finish.
if [ "$CLAUDECODE" = "1" ]; then
  _CLAUDE_HUD_TTY=""
  _pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    _t=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$_t" ] && [ "$_t" != "??" ]; then _CLAUDE_HUD_TTY="$_t"; break; fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_pid" ] && break
  done
  if [ -n "$_CLAUDE_HUD_TTY" ]; then
    trap 'echo "$(pwd)" > "$HOME/.claude-hud/${_CLAUDE_HUD_TTY}.cwd" 2>/dev/null' EXIT
  fi
fi
