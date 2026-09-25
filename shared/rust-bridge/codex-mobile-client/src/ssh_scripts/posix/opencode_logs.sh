# Read bounded startup diagnostics, not recent runtime output. Byte-limit first
# so legacy files with enormous newline-free records cannot flood the caller.
{{PROFILE_INIT}}
session_dir="$HOME/.litter/sessions/{{SESSION_ID}}"
# A just-exited server may still have buffered startup output draining. Wait
# only for that launch's private capture, never another live server's reader.
settle_startup_capture() {
  capture_pid=$1
  [ -n "$capture_pid" ] && ! kill -0 "$capture_pid" 2>/dev/null || return 0
  for capture_dir in "$session_dir"/.capture.*; do
    [ "$(cat "$capture_dir/agent.pid" 2>/dev/null)" = "$capture_pid" ] || continue
    settle_i=0
    while [ -d "$capture_dir" ] && [ "$settle_i" -lt 30 ]; do
      settle_i=$((settle_i + 1))
      sleep 0.01
    done
  done
}
settle_startup_capture "$(cat "$session_dir/agent.pid" 2>/dev/null)"
echo "--- startup out.log (first 64 KiB captured) ---"
tail -c 16384 "$session_dir/out.log" 2>/dev/null | tail -n 120
echo "--- startup err.log (first 64 KiB captured) ---"
tail -c 16384 "$session_dir/err.log" 2>/dev/null | tail -n 120
