#!/usr/bin/env bash
# Codex ⇄ mobile end-to-end runtime proof.
#
# `kittylitter probe` dials the daemon over iroh and uses the same websocket
# app-server path as a paired phone. Evidence is retained as mixed JSON-RPC
# frame logs so ordering and hydration can be audited after the run.
#
# Scenarios
#   1 availability       Codex is advertised and available
#   2 start-stream       a new session completes with a valid streaming lifecycle
#   3 resume-desktop     a pre-existing Codex desktop session is phone-readable
#   4 handoff-to-codex   a phone-created session lands in the Codex session store
#   5 tool-file-order    a tool creates a file with correctly interleaved events
#   6 reconnect          a cursor reconnect attaches rather than replacing state
#   7 compaction         manual context compaction completes
#   8 post-compaction    the compacted session rehydrates and accepts another turn
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/artifacts/codex-e2e}"
BIN="${KITTYLITTER_BIN:-$REPO_DIR/.build-stamps/kittylitter-dev/target/debug/kittylitter}"
PROOF_CWD="${CODEX_PROOF_CWD:-$REPO_DIR}"
ASSERT="$REPO_DIR/tools/scripts/assert-local-studio-proof.py"
RUN_STARTED_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"

mkdir -p "$OUT_DIR"

if [ ! -x "$BIN" ]; then
  echo "error: kittylitter binary not found at $BIN" >&2
  echo "hint: set KITTYLITTER_BIN, or build it first" >&2
  exit 1
fi

PASS=0
FAIL=0

record() {
  local name="$1" file="$2" what="$3" assertion="$4" expected="${5:-}"
  local command=(python3 "$ASSERT" "$assertion" "$file")
  if [ -n "$expected" ]; then
    command+=("$expected")
  fi
  if "${command[@]}"; then
    printf '  PASS  %-18s %s\n' "$name" "$what"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-18s %s\n' "$name" "$what"
    echo "        evidence: $file"
    FAIL=$((FAIL + 1))
  fi
}

record_grep() {
  local name="$1" file="$2" what="$3" pattern="$4"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    printf '  PASS  %-18s %s\n' "$name" "$what"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-18s %s\n' "$name" "$what"
    echo "        evidence: $file"
    FAIL=$((FAIL + 1))
  fi
}

echo "Codex E2E proof"
echo "  binary:   $BIN"
echo "  cwd:      $PROOF_CWD"
echo "  evidence: $OUT_DIR"
echo

echo "[1/8] agent availability"
"$BIN" probe --linger-secs 1 --timeout-secs 25 \
  >"$OUT_DIR/01-availability.json" 2>&1
record availability "$OUT_DIR/01-availability.json" \
  "Codex is advertised as available" \
  availability codex

echo "[2/8] start session + streaming lifecycle"
"$BIN" probe --agent codex --wire websocket \
  --start-thread-params "{\"cwd\":\"$PROOF_CWD\",\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\"}" \
  --method turn/start \
  --params '{"input":[{"type":"text","text":"Reply with exactly CODEX_START_OK and nothing else."}]}' \
  --until-method turn/completed \
  --linger-secs 120 --timeout-secs 45 \
  >"$OUT_DIR/02-start-stream.json" 2>&1
record start "$OUT_DIR/02-start-stream.json" \
  "the turn completed with the exact assistant response" \
  turn-agent CODEX_START_OK
record stream-lifecycle "$OUT_DIR/02-start-stream.json" \
  "all streamed deltas are bracketed by matching item lifecycles" \
  streaming-lifecycle

NEW_THREAD_ID="$(grep -oE '"threadId"[[:space:]]*:[[:space:]]*"[^"]+"' "$OUT_DIR/02-start-stream.json" \
  | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
echo "        thread: ${NEW_THREAD_ID:-<none>}"

echo "[3/8] resume a desktop-created Codex session"
"$BIN" probe --agent codex --wire websocket --method thread/list --params '{}' \
  --linger-secs 1 --timeout-secs 30 \
  >"$OUT_DIR/03a-thread-list.json" 2>&1
python3 - "$OUT_DIR/03a-thread-list.json" "$RUN_STARTED_MS" \
  >"$OUT_DIR/03-desktop-thread-id.txt" 2>/dev/null <<'PY'
import json, sys

raw = open(sys.argv[1], errors="replace").read()
started_ms = int(sys.argv[2])

def objects(text):
    depth = 0
    start = None
    quoted = False
    escaped = False
    for index, char in enumerate(text):
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    yield json.loads(text[start:index + 1])
                except Exception:
                    pass
                start = None

for document in objects(raw):
    result = document.get("result") or {}
    for thread in result.get("data") or result.get("threads") or []:
        thread_id = thread.get("id")
        created = thread.get("createdAt") or 0
        created_ms = created if created >= 1_000_000_000_000 else created * 1000
        path = thread.get("path") or ""
        if not thread_id or created_ms >= started_ms:
            continue
        if "/.codex/sessions/" not in path:
            continue
        print(thread_id)
        raise SystemExit
PY

DESKTOP_THREAD_ID="$(tr -d '[:space:]' <"$OUT_DIR/03-desktop-thread-id.txt" 2>/dev/null)"
echo "        desktop thread: ${DESKTOP_THREAD_ID:-<none>}"
if [ -n "$DESKTOP_THREAD_ID" ]; then
  "$BIN" probe --agent codex --wire websocket --method thread/read \
    --params "{\"threadId\":\"$DESKTOP_THREAD_ID\",\"includeTurns\":true}" \
    --linger-secs 3 --timeout-secs 30 \
    >"$OUT_DIR/03b-thread-read.json" 2>&1
  record_grep resume-desktop "$OUT_DIR/03b-thread-read.json" \
    "a pre-existing Codex desktop session is readable over the phone path" \
    "\"(id|threadId)\": \"$DESKTOP_THREAD_ID\""
else
  echo "  FAIL  resume-desktop     no pre-existing Codex session was found"
  FAIL=$((FAIL + 1))
fi

echo "[4/8] phone-created session is visible in the Codex store"
if [ -n "${NEW_THREAD_ID:-}" ]; then
  "$BIN" probe --agent codex --wire websocket --method thread/list --params '{}' \
    --linger-secs 1 --timeout-secs 30 \
    >"$OUT_DIR/04-handoff-list.json" 2>&1
  python3 - "$OUT_DIR/04-handoff-list.json" "$NEW_THREAD_ID" \
    >"$OUT_DIR/04-handoff-path.txt" 2>/dev/null <<'PY'
import json, sys

raw = open(sys.argv[1], errors="replace").read()
wanted = sys.argv[2]
decoder = json.JSONDecoder()
for index, char in enumerate(raw):
    if char != "{":
        continue
    try:
        document, _ = decoder.raw_decode(raw[index:])
    except Exception:
        continue
    result = document.get("result") or {}
    for thread in result.get("data") or result.get("threads") or []:
        if thread.get("id") == wanted:
            print(thread.get("path") or "")
            raise SystemExit
PY
  record_grep handoff-to-codex "$OUT_DIR/04-handoff-path.txt" \
    "the phone-created session is persisted in the Codex session store" \
    '/\.codex/sessions/.*\.jsonl$'
else
  echo "  FAIL  handoff-to-codex   scenario 2 produced no thread id"
  FAIL=$((FAIL + 1))
fi

echo "[5/8] tool/file creation and event ordering"
PROOF_FILE="$OUT_DIR/runtime-file.txt"
rm -f "$PROOF_FILE"
if [ -n "${NEW_THREAD_ID:-}" ]; then
  TOOL_PROMPT="Use the shell tool exactly once to run this command: printf 'CODEX_FILE_OK\\n' > '$PROOF_FILE' && cat '$PROOF_FILE'. Do not use any other tool. After it succeeds, reply with exactly CODEX_TOOL_OK and nothing else."
  TOOL_PARAMS="$(python3 -c 'import json,sys; print(json.dumps({"threadId":sys.argv[1],"input":[{"type":"text","text":sys.argv[2]}]}))' "$NEW_THREAD_ID" "$TOOL_PROMPT")"
  "$BIN" probe --agent codex --wire websocket --method turn/start \
    --params "$TOOL_PARAMS" \
    --until-method turn/completed \
    --linger-secs 120 --timeout-secs 45 \
    >"$OUT_DIR/05-tool-file-order.json" 2>&1
  record tool-order "$OUT_DIR/05-tool-file-order.json" \
    "tool completion precedes the final streamed assistant response" \
    tool-file-order CODEX_TOOL_OK
  record tool-stream "$OUT_DIR/05-tool-file-order.json" \
    "tool and assistant deltas remain inside matching item lifecycles" \
    streaming-lifecycle
  record_grep file-created "$PROOF_FILE" \
    "the tool created the requested file with exact contents" \
    '^CODEX_FILE_OK$'
else
  echo "  FAIL  tool-order         scenario 2 produced no thread id"
  echo "  FAIL  tool-stream        scenario 2 produced no thread id"
  echo "  FAIL  file-created       scenario 2 produced no thread id"
  FAIL=$((FAIL + 3))
fi

echo "[6/8] reconnect from event cursor"
LAST_SEQ="$(grep -oE '"_alleycat_seq"[[:space:]]*:[[:space:]]*[0-9]+' "$OUT_DIR/05-tool-file-order.json" 2>/dev/null \
  | tail -1 | grep -oE '[0-9]+$')"
LAST_SEQ="${LAST_SEQ:-1}"
"$BIN" probe --agent codex --wire websocket --method thread/list \
  --repeat-resume-from "$LAST_SEQ" \
  --linger-secs 5 --timeout-secs 30 \
  >"$OUT_DIR/06-reconnect.json" 2>&1
grep -a 'probe: connect ok' "$OUT_DIR/06-reconnect.json" \
  | tail -1 >"$OUT_DIR/06-reattach.txt" 2>/dev/null
record_grep reconnect "$OUT_DIR/06-reattach.txt" \
  "the cursor reconnect attached to existing canonical state" \
  'attached=(Resumed|DriftReload)'

echo "[7/8] manual context compaction lifecycle"
if [ -n "${NEW_THREAD_ID:-}" ]; then
  "$BIN" probe --agent codex --wire websocket --method thread/compact/start \
    --params "{\"threadId\":\"$NEW_THREAD_ID\"}" \
    --until-method item/completed \
    --linger-secs 180 --timeout-secs 45 \
    >"$OUT_DIR/07-compaction.json" 2>&1
  record compaction "$OUT_DIR/07-compaction.json" \
    "context compaction emitted matching started/completed items" \
    compaction-lifecycle
else
  echo "  FAIL  compaction         scenario 2 produced no thread id"
  FAIL=$((FAIL + 1))
fi

echo "[8/8] compacted session rehydrates and continues"
if [ -n "${NEW_THREAD_ID:-}" ]; then
  "$BIN" probe --agent codex --wire websocket --method turn/start \
    --params "{\"threadId\":\"$NEW_THREAD_ID\",\"input\":[{\"type\":\"text\",\"text\":\"Reply with exactly CODEX_POST_COMPACTION_OK and nothing else.\"}]}" \
    --until-method turn/completed \
    --linger-secs 120 --timeout-secs 45 \
    >"$OUT_DIR/08a-post-compaction-turn.json" 2>&1
  record post-compaction "$OUT_DIR/08a-post-compaction-turn.json" \
    "the compacted session accepted another streamed turn" \
    turn-agent CODEX_POST_COMPACTION_OK
  record post-stream "$OUT_DIR/08a-post-compaction-turn.json" \
    "post-compaction streaming retained a valid lifecycle" \
    streaming-lifecycle
  "$BIN" probe --agent codex --wire websocket --method thread/read \
    --params "{\"threadId\":\"$NEW_THREAD_ID\",\"includeTurns\":true}" \
    --linger-secs 3 --timeout-secs 30 \
    >"$OUT_DIR/08b-post-compaction-read.json" 2>&1
  record compact-hydrated "$OUT_DIR/08b-post-compaction-read.json" \
    "a fresh client rehydrated the persisted compaction marker" \
    thread-has-compaction
  record post-turn-hydrated "$OUT_DIR/08b-post-compaction-read.json" \
    "a fresh client rehydrated the post-compaction assistant response" \
    thread-agent CODEX_POST_COMPACTION_OK
else
  echo "  FAIL  post-compaction    scenario 2 produced no thread id"
  echo "  FAIL  post-stream        scenario 2 produced no thread id"
  echo "  FAIL  compact-hydrated   scenario 2 produced no thread id"
  echo "  FAIL  post-turn-hydrated scenario 2 produced no thread id"
  FAIL=$((FAIL + 4))
fi

echo
echo "----------------------------------------"
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
echo "evidence written to $OUT_DIR"
[ "$FAIL" -eq 0 ]
