# Claude Code HUD: capture Bash sandbox CWD for accurate folder display.
# Uses EXIT trap to capture CWD AFTER the sandbox's "cd /project/root && command" finishes.
if [ "$CLAUDECODE" = "1" ]; then
  # Find TTY at startup (before anything runs)
  _CLAUDE_HUD_TTY=""
  _pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    _t=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$_t" ] && [ "$_t" != "??" ]; then _CLAUDE_HUD_TTY="$_t"; break; fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_pid" ] && break
  done
  unset _pid _t
  # Write CWD on exit (after sandbox cd + commands have run)
  if [ -n "$_CLAUDE_HUD_TTY" ]; then
    trap 'echo "$(pwd)" > "$HOME/.claude-hud/${_CLAUDE_HUD_TTY}.cwd" 2>/dev/null' EXIT
  fi
fi
