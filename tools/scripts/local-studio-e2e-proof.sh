#!/usr/bin/env bash
# Local Studio ⇄ mobile end-to-end proof harness.
#
# `kittylitter probe` dials the daemon over iroh and speaks the same JSON-RPC a
# paired phone speaks, so every scenario below exercises the real transport,
# the real Local Studio Pi runtime, and the real session store — not a mock.
#
# Scenarios
#   1  availability      local-studio is advertised and available
#   2  catalog           model/list returns the controller-scoped catalog
#   3  start             a new session starts and a turn completes in order
#   4  leave-return      reconnect from a cursor reattaches the same session
#   5  resume-desktop    a session created in Local Studio's own UI is readable
#   6  filesystem        the session can execute shell commands and search files
#   7  handoff-to-studio a phone-created session lands in Local Studio's own store
#   8  mid-turn-reconnect a detached tool keeps running and rehydrates on reconnect
#
# Usage:  tools/scripts/local-studio-e2e-proof.sh [output-dir]
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/artifacts/local-studio-e2e}"
BIN="${KITTYLITTER_BIN:-$REPO_DIR/.build-stamps/kittylitter-dev/target/debug/kittylitter}"
CWD="${LOCAL_STUDIO_PROOF_CWD:-$REPO_DIR}"
ASSERT="$REPO_DIR/tools/scripts/assert-local-studio-proof.py"

mkdir -p "$OUT_DIR"

# Epoch-ms at start of run. Scenario 5 uses this to pick a session that
# provably predates this harness, so "resume a desktop session" cannot be
# satisfied by a session the harness itself just created.
RUN_STARTED_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

if [ ! -x "$BIN" ]; then
  echo "error: kittylitter binary not found at $BIN" >&2
  echo "hint: set KITTYLITTER_BIN, or build it first" >&2
  exit 1
fi

PASS=0
FAIL=0

# record <name> <file> <predicate-description> <assertion> [expected]
record() {
  local name="$1" file="$2" what="$3" assertion="$4" expected="${5:-}"
  local command=(python3 "$ASSERT" "$assertion" "$file")
  if [ -n "$expected" ]; then
    command+=("$expected")
  fi
  if "${command[@]}"; then
    printf '  PASS  %-16s %s\n' "$name" "$what"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-16s %s\n' "$name" "$what"
    echo "        evidence: $file"
    FAIL=$((FAIL + 1))
  fi
}

# record_grep <name> <file> <predicate-description> <grep-pattern>
# Used only for plain-text evidence files produced by the harness itself.
record_grep() {
  local name="$1" file="$2" what="$3" pattern="$4"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    printf '  PASS  %-16s %s\n' "$name" "$what"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-16s %s\n' "$name" "$what"
    echo "        evidence: $file"
    FAIL=$((FAIL + 1))
  fi
}

echo "Local Studio E2E proof"
echo "  binary:   $BIN"
echo "  cwd:      $CWD"
echo "  evidence: $OUT_DIR"
echo

# ---------------------------------------------------------------- 1 availability
echo "[1/8] agent availability"
"$BIN" probe --linger-secs 1 --timeout-secs 25 \
  >"$OUT_DIR/01-availability.json" 2>&1
record availability "$OUT_DIR/01-availability.json" \
  "local-studio advertised as available" \
  availability

# ------------------------------------------------------------------- 2 catalog
echo "[2/8] controller-scoped model catalog"
"$BIN" probe --agent local-studio --method model/list \
  --linger-secs 1 --timeout-secs 30 \
  >"$OUT_DIR/02-model-list.json" 2>&1
record catalog "$OUT_DIR/02-model-list.json" \
  "model/list returns a catalog" \
  catalog

# --------------------------------------------------------------------- 3 start
# A phone starting a fresh Local Studio session and completing one turn.
echo "[3/8] start session + complete a turn"
"$BIN" probe --agent local-studio \
  --start-thread-params "{\"cwd\":\"$CWD\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}" \
  --method turn/start \
  --params '{"input":[{"type":"text","text":"Reply with exactly LOCAL_STUDIO_START_OK and nothing else."}]}' \
  --until-method turn/completed \
  --linger-secs 90 --timeout-secs 45 \
  >"$OUT_DIR/03-start-turn.json" 2>&1
record start "$OUT_DIR/03-start-turn.json" \
  "turn completed successfully with the exact assistant response" \
  turn-agent LOCAL_STUDIO_START_OK

NEW_THREAD_ID="$(grep -oE '"threadId"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT_DIR/03-start-turn.json" \
  | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
echo "        thread: ${NEW_THREAD_ID:-<none>}"

# -------------------------------------------------------------- 4 leave/return
# Simulates backgrounding the app and reconnecting: a second connect on the same
# endpoint identity carrying the highest observed `_alleycat_seq`. The host must
# reattach rather than mint a fresh session.
echo "[4/8] leave and return (reconnect from cursor)"
LAST_SEQ="$(grep -oE '"_alleycat_seq"[[:space:]]*:[[:space:]]*[0-9]+' "$OUT_DIR/03-start-turn.json" \
  | tail -1 | grep -oE '[0-9]+$')"
LAST_SEQ="${LAST_SEQ:-1}"
echo "        resuming from seq $LAST_SEQ"
"$BIN" probe --agent local-studio --method thread/list \
  --repeat-resume-from "$LAST_SEQ" \
  --linger-secs 5 --timeout-secs 30 \
  >"$OUT_DIR/04-leave-return.json" 2>&1
# The first connect is necessarily Fresh; the second carries the cursor. Assert
# on the second specifically, otherwise a host that always minted a new session
# would still pass.
grep -a 'probe: connect ok' "$OUT_DIR/04-leave-return.json" \
  | tail -1 >"$OUT_DIR/04-reattach.txt" 2>/dev/null
record_grep leave-return "$OUT_DIR/04-reattach.txt" \
  "reconnect with a cursor reattached the existing session" \
  'attached=(Resumed|DriftReload)'

# ------------------------------------------------------------ 5 resume desktop
# A session that Local Studio's own UI created, read back over the phone path.
echo "[5/8] resume a desktop-created session"
"$BIN" probe --agent local-studio --method thread/list --params '{}' \
  --linger-secs 1 --timeout-secs 30 \
  >"$OUT_DIR/05a-thread-list.json" 2>&1

# The heredoc deliberately sits outside a command substitution: bash 3.2, which
# is still /bin/bash on macOS, mis-parses heredocs nested inside `$(...)`.
python3 - "$OUT_DIR/05a-thread-list.json" "$RUN_STARTED_MS" \
  >"$OUT_DIR/05-desktop-thread-id.txt" 2>/dev/null <<'PY'
import json, sys

raw = open(sys.argv[1], errors="replace").read()
started_ms = int(sys.argv[2])


def json_objects(text):
    """Yield every top-level JSON object in a stream of framed probe output.

    The probe interleaves `→`/`←` log lines with pretty-printed JSON, so a
    regex spanning the first `{` to the last `}` produces one unparseable
    blob. Scan with a brace counter instead, ignoring braces inside strings.
    """
    depth = 0
    start = None
    in_string = False
    escaped = False
    for i, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth:
                depth -= 1
                if depth == 0 and start is not None:
                    try:
                        yield json.loads(text[start:i + 1])
                    except Exception:
                        pass
                    start = None


for doc in json_objects(raw):
    result = doc.get("result") or {}
    # thread/list pages the array under `data`; tolerate the other spellings
    # so this keeps working if the bridge is realigned with codex app-server.
    threads = result.get("data") or result.get("threads") or result.get("items") or []
    for t in threads:
        tid = t.get("id")
        created = t.get("createdAt") or 0
        path = t.get("path") or ""
        # Require a session that (a) predates this run, so the harness cannot
        # have created it, and (b) lives in Local Studio's own pi-agent session
        # store, so it is genuinely a Local Studio session rather than a
        # litter-local one.
        if not tid or created >= started_ms:
            continue
        if "/pi-agent/sessions/" not in path:
            continue
        print(tid)
        sys.exit()
PY

DESKTOP_THREAD_ID="$(tr -d '[:space:]' <"$OUT_DIR/05-desktop-thread-id.txt" 2>/dev/null)"
echo "        desktop thread: ${DESKTOP_THREAD_ID:-<none>}"

if [ -n "$DESKTOP_THREAD_ID" ]; then
  "$BIN" probe --agent local-studio --method thread/read \
    --params "{\"threadId\":\"$DESKTOP_THREAD_ID\"}" \
    --linger-secs 3 --timeout-secs 30 \
    >"$OUT_DIR/05b-thread-read.json" 2>&1
  # Assert the response actually carries the requested session back, not just
  # that some `result` came through.
  record_grep resume-desktop "$OUT_DIR/05b-thread-read.json" \
    "a pre-existing Local Studio session is readable over the phone path" \
    "\"(id|threadId|sessionId)\": \"$DESKTOP_THREAD_ID\""
else
  echo "  FAIL  resume-desktop   no session predating this run was found"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------- 6 filesystem
echo "[6/8] filesystem access"
"$BIN" probe --agent local-studio \
  --start-thread-params "{\"cwd\":\"$CWD\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}" \
  --method turn/start \
  --params '{"input":[{"type":"text","text":"Run the shell command `pwd` exactly once, then reply with only the directory it printed."}]}' \
  --until-method turn/completed \
  --linger-secs 90 --timeout-secs 45 \
  >"$OUT_DIR/06a-fs-exec.json" 2>&1
record fs-exec "$OUT_DIR/06a-fs-exec.json" \
  "shell command executed inside the session cwd" \
  turn-agent "$CWD"

"$BIN" probe --agent local-studio --method fuzzyFileSearch \
  --params "{\"query\":\"local_studio\",\"roots\":[\"$CWD\"]}" \
  --linger-secs 3 --timeout-secs 30 \
  >"$OUT_DIR/06b-fs-search.json" 2>&1
record fs-search "$OUT_DIR/06b-fs-search.json" \
  "fuzzy file search returns repository paths" \
  files

# ------------------------------------------------------- 7 handoff to Local Studio
# The reverse of scenario 5. Scenario 5 proved desktop→phone; this proves
# phone→desktop by showing the session created in scenario 3 is now listed with
# a path inside Local Studio's own pi-agent session store — the same store the
# desktop UI reads — so it is resumable there.
echo "[7/8] phone-created session is visible to Local Studio"
if [ -n "${NEW_THREAD_ID:-}" ]; then
  "$BIN" probe --agent local-studio --method thread/list --params '{}' \
    --linger-secs 1 --timeout-secs 30 \
    >"$OUT_DIR/07-handoff-list.json" 2>&1

  python3 - "$OUT_DIR/07-handoff-list.json" "$NEW_THREAD_ID" \
    >"$OUT_DIR/07-handoff-path.txt" 2>/dev/null <<'PY'
import json, sys

raw = open(sys.argv[1], errors="replace").read()
wanted = sys.argv[2]


def json_objects(text):
    depth = 0
    start = None
    in_string = False
    escaped = False
    for i, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth:
                depth -= 1
                if depth == 0 and start is not None:
                    try:
                        yield json.loads(text[start:i + 1])
                    except Exception:
                        pass
                    start = None


for doc in json_objects(raw):
    result = doc.get("result") or {}
    for t in result.get("data") or result.get("threads") or []:
        if t.get("id") == wanted:
            print(t.get("path") or "")
            sys.exit()
PY

  HANDOFF_PATH="$(cat "$OUT_DIR/07-handoff-path.txt" 2>/dev/null)"
  echo "        path: ${HANDOFF_PATH:-<not listed>}"
  record_grep handoff-to-studio "$OUT_DIR/07-handoff-path.txt" \
    "the phone-created session is stored in Local Studio's session store" \
    '/pi-agent/sessions/.*\.jsonl$'
else
  echo "  FAIL  handoff-to-studio  scenario 3 produced no thread id"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------- 8 mid-turn reconnect
# Disconnect immediately after turn/start, while the shell command still has
# several seconds left. A fresh connection must see the canonical thread and
# turn as active, then later hydrate the completed command output and final
# assistant response without the original client remaining attached.
echo "[8/8] mid-turn disconnect + reconnect hydration"
"$BIN" probe --agent local-studio \
  --start-thread-params "{\"cwd\":\"$CWD\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}" \
  --method turn/start \
  --params '{"input":[{"type":"text","text":"Run the shell command `sleep 10; echo MIDTURN_SERVER_OK` exactly once, then reply with exactly MIDTURN_FINISHED."}]}' \
  --until-method turn/started \
  --linger-secs 1 --timeout-secs 45 \
  >"$OUT_DIR/08a-midturn-start.json" 2>&1

MIDTURN_THREAD_ID="$(grep -oE '"threadId"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT_DIR/08a-midturn-start.json" \
  | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
echo "        thread: ${MIDTURN_THREAD_ID:-<none>}"

if [ -n "$MIDTURN_THREAD_ID" ]; then
  "$BIN" probe --agent local-studio --method thread/read \
    --params "{\"threadId\":\"$MIDTURN_THREAD_ID\",\"includeTurns\":true}" \
    --linger-secs 1 --timeout-secs 30 \
    >"$OUT_DIR/08b-midturn-active.json" 2>&1
  record midturn-active "$OUT_DIR/08b-midturn-active.json" \
    "a fresh client sees the detached turn still active" \
    thread-active

  : >"$OUT_DIR/08c-midturn-finished.json"
  for _attempt in 1 2 3 4 5 6 7 8; do
    "$BIN" probe --agent local-studio --method thread/read \
      --params "{\"threadId\":\"$MIDTURN_THREAD_ID\",\"includeTurns\":true}" \
      --linger-secs 1 --timeout-secs 30 \
      >"$OUT_DIR/08c-midturn-finished.json" 2>&1
    if python3 "$ASSERT" thread-agent \
      "$OUT_DIR/08c-midturn-finished.json" MIDTURN_FINISHED; then
      break
    fi
    sleep 2
  done
  record midturn-output "$OUT_DIR/08c-midturn-finished.json" \
    "the detached shell command completed server-side" \
    thread-command MIDTURN_SERVER_OK
  record midturn-finished "$OUT_DIR/08c-midturn-finished.json" \
    "the final assistant response rehydrated on a fresh client" \
    thread-agent MIDTURN_FINISHED
else
  echo "  FAIL  midturn-active    scenario produced no thread id"
  echo "  FAIL  midturn-output    scenario produced no thread id"
  echo "  FAIL  midturn-finished  scenario produced no thread id"
  FAIL=$((FAIL + 3))
fi

echo
echo "----------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
echo "evidence written to $OUT_DIR"
[ "$FAIL" -eq 0 ]
