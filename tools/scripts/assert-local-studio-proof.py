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


def notifications(
    documents: list[dict[str, Any]],
) -> Iterator[tuple[int, str, dict[str, Any]]]:
    for index, document in enumerate(documents):
        method = document.get("method")
        params = document.get("params")
        if isinstance(method, str) and isinstance(params, dict):
            yield index, method, params


def streaming_lifecycle(documents: list[dict[str, Any]]) -> bool:
    open_items: dict[str, dict[str, Any]] = {}
    completed_ids: set[str] = set()
    agent_delta_count = 0
    completed_agent_count = 0

    for _, method, params in notifications(documents):
        item = params.get("item") or {}
        item_id = item.get("id")
        item_type = item.get("type")

        if method == "item/started" and isinstance(item_id, str):
            if item_id in open_items or item_id in completed_ids:
                return False
            open_items[item_id] = {
                "type": item_type,
                "agent_text": "",
            }
            continue

        if method in {
            "item/agentMessage/delta",
            "item/reasoning/textDelta",
            "item/reasoning/summaryTextDelta",
            "item/commandExecution/outputDelta",
            "item/dynamicToolCall/argumentsDelta",
        }:
            delta_item_id = params.get("itemId")
            if not isinstance(delta_item_id, str) or delta_item_id not in open_items:
                return False
            if method == "item/agentMessage/delta":
                delta = params.get("delta")
                if not isinstance(delta, str):
                    return False
                open_items[delta_item_id]["agent_text"] += delta
                agent_delta_count += 1
            continue

        if method == "item/completed" and isinstance(item_id, str):
            state = open_items.pop(item_id, None)
            if state is None:
                return False
            completed_ids.add(item_id)
            if item_type == "agentMessage":
                completed_agent_count += 1
                streamed = state["agent_text"]
                final = item.get("text")
                if streamed and final != streamed:
                    return False

    return (
        not open_items
        and agent_delta_count > 0
        and completed_agent_count > 0
        and any(
            method == "turn/completed"
            and completed_turn(params.get("turn") or {})
            for _, method, params in notifications(documents)
        )
    )


def tool_file_order(documents: list[dict[str, Any]], expected: str) -> bool:
    turn_started: int | None = None
    command_started: dict[str, int] = {}
    command_completed: list[int] = []
    reasoning_started: dict[str, int] = {}
    reasoning_completed: list[int] = []
    agent_completed: int | None = None
    turn_completed: int | None = None

    for index, method, params in notifications(documents):
        item = params.get("item") or {}
        item_id = item.get("id")
        item_type = item.get("type")

        if method == "turn/started" and turn_started is None:
            turn_started = index
        elif method == "item/started" and isinstance(item_id, str):
            if item_type == "commandExecution":
                command_started[item_id] = index
            elif item_type == "reasoning":
                reasoning_started[item_id] = index
        elif method == "item/completed" and isinstance(item_id, str):
            if item_type == "commandExecution":
                started = command_started.get(item_id)
                if started is None or started >= index or item.get("status") != "completed":
                    return False
                command_completed.append(index)
            elif item_type == "reasoning":
                started = reasoning_started.get(item_id)
                if started is None or started >= index:
                    return False
                reasoning_completed.append(index)
            elif item_type == "agentMessage" and item.get("text") == expected:
                agent_completed = index
        elif (
            method == "turn/completed"
            and completed_turn(params.get("turn") or {})
        ):
            turn_completed = index

    if (
        turn_started is None
        or not command_started
        or not command_completed
        or agent_completed is None
        or turn_completed is None
    ):
        return False

    first_command = min(command_started.values())
    last_command = max(command_completed)
    if not (
        turn_started < first_command < last_command < agent_completed < turn_completed
    ):
        return False
    return all(index < agent_completed for index in reasoning_completed)


def compaction_lifecycle(documents: list[dict[str, Any]]) -> bool:
    started: dict[str, int] = {}
    for index, method, params in notifications(documents):
        item = params.get("item") or {}
        item_id = item.get("id")
        if item.get("type") != "contextCompaction" or not isinstance(item_id, str):
            continue
        if method == "item/started":
            started[item_id] = index
        elif method == "item/completed":
            start_index = started.get(item_id)
            if start_index is not None and start_index < index:
                return True
    return False


def thread_has_compaction(documents: list[dict[str, Any]]) -> bool:
    return any(
        item.get("type") == "contextCompaction"
        for document in documents
        for turn in (((document.get("result") or {}).get("thread") or {}).get("turns") or [])
        for item in turn.get("items") or []
    )


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print(
            "usage: assert-local-studio-proof.py "
            "<availability|catalog|files|turn-agent|thread-active|"
            "thread-agent|thread-command|streaming-lifecycle|tool-file-order|"
            "compaction-lifecycle|thread-has-compaction> "
            "<evidence-file> [expected]",
            file=sys.stderr,
        )
        return 2

    assertion = sys.argv[1]
    documents = list(json_objects(Path(sys.argv[2]).read_text(errors="replace")))
    expected = sys.argv[3] if len(sys.argv) == 4 else None

    if assertion == "availability":
        agent_name = expected or "local-studio"
        passed = any(
            document.get("ok") is True
            and any(
                agent.get("name") == agent_name
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
    elif assertion == "streaming-lifecycle":
        passed = streaming_lifecycle(documents)
    elif assertion == "tool-file-order" and expected is not None:
        passed = tool_file_order(documents, expected)
    elif assertion == "compaction-lifecycle":
        passed = compaction_lifecycle(documents)
    elif assertion == "thread-has-compaction":
        passed = thread_has_compaction(documents)
    else:
        print(f"unknown or incomplete assertion: {assertion}", file=sys.stderr)
        return 2

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
