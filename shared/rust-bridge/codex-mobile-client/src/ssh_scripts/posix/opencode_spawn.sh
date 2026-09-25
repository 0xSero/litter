# Retain at most the first 64 KiB of each OpenCode startup stream, then drain
# further output without storing it. These are startup diagnostics, not a live
# log tail. The detached supervisor owns readers through server exit.
{{PROFILE_INIT}}
session_dir="$HOME/.litter/sessions/{{SESSION_ID}}"
umask 077
mkdir -p "$session_dir" || exit 1
capture_dir=$(mktemp -d "$session_dir/.capture.XXXXXX") || exit 1
if ! cat >"$capture_dir/supervisor.sh" <<'SUPERVISOR'
session_dir=$1
capture_dir=$2
bin=$3
port=$4
agent_pid=
out_reader=
err_reader=

finish() {
  trap '' TERM INT
  if [ -n "$agent_pid" ]; then
    kill -TERM "$agent_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$agent_pid" 2>/dev/null || true
    wait "$agent_pid" 2>/dev/null || true
  fi
  # Let EOF flush startup diagnostics before cancellation. Descendants may
  # retain writer FDs, so this grace is bounded rather than waiting on EOF.
  i=0
  while [ "$i" -lt 20 ]; do
    if ! kill -0 "$out_reader" 2>/dev/null && ! kill -0 "$err_reader" 2>/dev/null; then
      break
    fi
    i=$((i + 1))
    sleep 0.01
  done
  for reader in "$out_reader" "$err_reader"; do
    [ -n "$reader" ] || continue
    kill -TERM "$reader" 2>/dev/null || true
    wait "$reader" 2>/dev/null || true
  done
  # Each launch owns only its private helper/FIFOs. Public diagnostics and PID
  # may already belong to a concurrent launch and must remain untouched here.
  rm -f "$capture_dir/out" "$capture_dir/err" "$capture_dir/supervisor.sh" \
    "$capture_dir/supervisor.pid" "$capture_dir/agent.pid"
  rmdir "$capture_dir" 2>/dev/null || true
}
trap finish 0
setup_stopping=0
trap 'setup_stopping=1' TERM INT
trap '' HUP
printf '%s\n' "$$" >"$capture_dir/supervisor.pid" || exit 1

capture() {
  # Keep a reader FD open while the bounded child exits: the server must never
  # see SIGPIPE at the capture limit, including if opening the log fails.
  exec 3<&0
  copy_pid=
  stopping=0
  trap 'stopping=1; [ -z "$copy_pid" ] || kill -KILL "$copy_pid" 2>/dev/null || true' TERM INT
  head -c 65536 <&3 3<&- >"$1" 2>/dev/null &
  copy_pid=$!
  # Also handle cancellation between spawning head and assigning its PID.
  [ "$stopping" -eq 0 ] || kill -KILL "$copy_pid" 2>/dev/null || true
  wait "$copy_pid" 2>/dev/null || true
  if [ "$stopping" -ne 0 ]; then
    wait "$copy_pid" 2>/dev/null || true
    exit
  fi
  copy_pid=
  trap - TERM INT
  [ "$stopping" -eq 0 ] || exit
  # GNU/BSD/BusyBox head support -c. If it fails or is unavailable, still drain
  # rather than imposing a new remote dependency or terminating the server.
  exec cat <&3 3<&- >/dev/null
}

mkfifo "$capture_dir/out" "$capture_dir/err" || exit 1
capture "$session_dir/out.log" <"$capture_dir/out" &
out_reader=$!
capture "$session_dir/err.log" <"$capture_dir/err" &
err_reader=$!
"$bin" serve --port="$port" </dev/null >"$capture_dir/out" 2>"$capture_dir/err" &
agent_pid=$!
printf '%s\n' "$agent_pid" >"$session_dir/agent.pid" || exit 1
# Publish private readiness last, only after every required PID write succeeds.
printf '%s\n' "$agent_pid" >"$capture_dir/agent.pid" || exit 1
# Defer setup cancellation until every forked child has an owned PID.
trap 'exit 143' TERM INT
[ "$setup_stopping" -eq 0 ] || exit 143
wait "$agent_pid"
status=$?
agent_pid=
exit "$status"
SUPERVISOR
then
  rm -f "$capture_dir/supervisor.sh"
  rmdir "$capture_dir" 2>/dev/null || true
  exit 1
fi
if command -v setsid >/dev/null 2>&1; then
  nohup setsid sh "$capture_dir/supervisor.sh" "$session_dir" "$capture_dir" {{BIN}} {{PORT}} </dev/null >/dev/null 2>&1 &
else
  nohup sh "$capture_dir/supervisor.sh" "$session_dir" "$capture_dir" {{BIN}} {{PORT}} </dev/null >/dev/null 2>&1 &
fi
launcher_pid=$!
# The supervisor publishes the actual server PID, not the pipeline/reader PID.
# Give it a bounded startup handshake; a failed helper must not hang SSH exec.
i=0
while [ ! -s "$capture_dir/agent.pid" ] && kill -0 "$launcher_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
  i=$((i + 1))
  sleep 0.01
done
pid=$(cat "$capture_dir/agent.pid" 2>/dev/null || true)
sleep 0.05
if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
  # This private PID cannot target a concurrently launched supervisor.
  supervisor_pid=$(cat "$capture_dir/supervisor.pid" 2>/dev/null || true)
  [ -z "$supervisor_pid" ] || kill -TERM "$supervisor_pid" 2>/dev/null || true
  if [ -z "$supervisor_pid" ] && ! kill -0 "$launcher_pid" 2>/dev/null; then
    rm -f "$capture_dir/supervisor.sh"
    rmdir "$capture_dir" 2>/dev/null || true
  fi
  i=0
  while [ -d "$capture_dir" ] && [ "$i" -lt 30 ]; do
    i=$((i + 1))
    sleep 0.01
  done
  echo "opencode exited immediately after launch" >&2
  echo "--- startup out.log (first 64 KiB captured) ---" >&2
  (tail -c 16384 "$session_dir/out.log" 2>/dev/null | tail -n 120) >&2
  echo "--- startup err.log (first 64 KiB captured) ---" >&2
  (tail -c 16384 "$session_dir/err.log" 2>/dev/null | tail -n 120) >&2
  exit 1
fi
printf '%s\n' "$session_dir"
