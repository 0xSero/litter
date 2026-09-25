# Poll http://127.0.0.1:PORT/global/health on the remote until opencode
# reports healthy or the underlying process dies. Without curl we fall
# through to "assume healthy after a brief delay" since the alternative is
# blocking the bootstrap on a host with no http client.
{{PROFILE_INIT}}
port={{PORT}}
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
url="http://127.0.0.1:${port}/global/health"
has_curl=0
if command -v curl >/dev/null 2>&1; then
  has_curl=1
fi

i=0
while [ "$i" -lt 100 ]; do
  i=$((i + 1))
  if [ "$has_curl" -eq 1 ]; then
    body=$(curl -fsS --max-time 1 "$url" 2>/dev/null || true)
    case "$body" in
      *'"healthy":true'*|*'"healthy": true'*)
        exit 0
        ;;
    esac
  fi

  pid=$(cat "$session_dir/agent.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    settle_startup_capture "$pid"
    echo "opencode exited before reporting healthy at $url" >&2
    echo "--- startup out.log (first 64 KiB captured) ---" >&2
    (tail -c 16384 "$session_dir/out.log" 2>/dev/null | tail -n 120) >&2
    echo "--- startup err.log (first 64 KiB captured) ---" >&2
    (tail -c 16384 "$session_dir/err.log" 2>/dev/null | tail -n 120) >&2
    exit 1
  fi
  if [ "$has_curl" -ne 1 ] && [ "$i" -ge 10 ]; then
    exit 0
  fi
  sleep 0.1
done

echo "opencode did not become healthy at $url" >&2
echo "--- startup out.log (first 64 KiB captured) ---" >&2
(tail -c 16384 "$session_dir/out.log" 2>/dev/null | tail -n 120) >&2
echo "--- startup err.log (first 64 KiB captured) ---" >&2
(tail -c 16384 "$session_dir/err.log" 2>/dev/null | tail -n 120) >&2
exit 1
