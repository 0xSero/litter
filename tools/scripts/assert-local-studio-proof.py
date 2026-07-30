#!/usr/bin/env python3
"""Strict assertions for kittylitter's mixed log/JSON proof output."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Iterator


def json_objects(text: str) -> Iterator[dict[str, Any]]:
    depth = 0
    start: int | None = None
    in_string = False
    escaped = False
    for index, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}" and depth:
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    value = json.loads(text[start : index + 1])
                except json.JSONDecodeError:
                    pass
                else:
                    if isinstance(value, dict):
                        yield value
                start = None


def completed_turn(turn: dict[str, Any]) -> bool:
    return turn.get("status") == "completed" and not turn.get("error")


def turn_agent_text(documents: list[dict[str, Any]], expected: str) -> bool:
    turn_ok = any(
        document.get("method") == "turn/completed"
        and completed_turn((document.get("params") or {}).get("turn") or {})
        for document in documents
    )
    assistant_ok = any(
        document.get("method") == "item/completed"
        and ((document.get("params") or {}).get("item") or {}).get("type")
        == "agentMessage"
        and ((document.get("params") or {}).get("item") or {}).get("text")
        == expected
        for document in documents
    )
    return turn_ok and assistant_ok


def completed_thread_turns(
    documents: list[dict[str, Any]],
) -> Iterator[dict[str, Any]]:
    for document in documents:
        thread = (document.get("result") or {}).get("thread") or {}
        for turn in thread.get("turns") or []:
            if completed_turn(turn):
                yield turn


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(
            "usage: assert-local-studio-proof.py "
            "<availability|catalog|files|turn-agent|thread-active|"
            "thread-agent|thread-command> <evidence-file> [expected]",
            file=sys.stderr,
        )
        return 2

    assertion = sys.argv[1]
    documents = list(json_objects(Path(sys.argv[2]).read_text(errors="replace")))
    expected = sys.argv[3] if len(sys.argv) == 4 else None

    if assertion == "availability":
        passed = any(
            document.get("ok") is True
            and any(
                agent.get("name") == "local-studio"
                and agent.get("available") is True
                for agent in document.get("agents") or []
            )
            for document in documents
        )
    elif assertion == "catalog":
        passed = any(
            isinstance((document.get("result") or {}).get("data"), list)
            and bool((document.get("result") or {}).get("data"))
            for document in documents
        )
    elif assertion == "files":
        passed = any(
            isinstance((document.get("result") or {}).get("files"), list)
            and bool((document.get("result") or {}).get("files"))
            for document in documents
        )
    elif assertion == "turn-agent" and expected is not None:
        passed = turn_agent_text(documents, expected)
    elif assertion == "thread-active":
        passed = any(
            ((document.get("result") or {}).get("thread") or {})
            .get("status", {})
            .get("type")
            == "active"
            and any(
                turn.get("status") == "inProgress"
                for turn in (
                    ((document.get("result") or {}).get("thread") or {}).get(
                        "turns"
                    )
                    or []
                )
            )
            for document in documents
        )
    elif assertion == "thread-agent" and expected is not None:
        passed = any(
            item.get("type") == "agentMessage" and item.get("text") == expected
            for turn in completed_thread_turns(documents)
            for item in turn.get("items") or []
        )
    elif assertion == "thread-command" and expected is not None:
        passed = any(
            item.get("type") == "commandExecution"
            and item.get("status") == "completed"
            and expected in (item.get("aggregatedOutput") or "")
            for turn in completed_thread_turns(documents)
            for item in turn.get("items") or []
        )
    else:
        print(f"unknown or incomplete assertion: {assertion}", file=sys.stderr)
        return 2

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
