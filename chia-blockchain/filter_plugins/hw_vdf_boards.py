"""Merge hw_vdf_client --list output with the role's installed wrappers."""

from __future__ import annotations

import base64
import re
from collections.abc import Callable
from typing import Any

from ansible.errors import AnsibleFilterError

_MARKER = "# Managed by the chia-blockchain Ansible role."
_DEVICE = "Device "
_NO_BOARDS = "Auto-discovery found 0 boards; set chia_darwin_hw_vdf_boards."
_ROW = re.compile(r"^Device [0-9]+: '.*', loc ([0-9]+), serial '([^']*)'$")
_ASSIGNMENT = re.compile(r"^(?P<name>[A-Z_]+)=(?P<value>.*)$", re.MULTILINE)
_COMMENT = re.compile(r"\s+#.*$")


def _last(text: str, name: str) -> str | None:
    values = []
    for match in _ASSIGNMENT.finditer(text):
        if match.group("name") == name:
            values.append(match.group("value"))
    if not values:
        return None
    value = values[-1].strip()
    if value[:1] in ("'", '"'):
        end = value.find(value[0], 1)
        if end != -1:
            return value[1:end]
    return _COMMENT.sub("", value).strip()


def _matches(stored: str, visible: str) -> bool:
    return stored == visible or (visible.endswith("A") and stored == visible[:-1])


def _same_serial(left: str, right: str) -> bool:
    return _matches(left, right) or _matches(right, left)


def _is_expected(board: dict[str, Any], serial: str) -> bool:
    return _matches(board["expected_serial"], serial)


def _parse_claim(text: str, board_id: int) -> dict[str, Any] | None:
    if _MARKER not in text:
        return None
    location = _last(text, "DEVICE_LOC")
    if location is None:
        return None
    serial = _last(text, "SERIAL")
    if not serial or not location.isdigit():
        message = f"Board {board_id} has invalid SERIAL or DEVICE_LOC."
        raise AnsibleFilterError(message)
    return {
        "id": int(board_id),
        "device_loc": int(location),
        "expected_serial": serial,
    }


def _slot_id(item: Any) -> int:
    return int(item["id"]) if isinstance(item, dict) else int(item)


def _claim_entries(
    results: list[dict[str, Any]],
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    entries: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for result in results:
        board_id = _slot_id(result["item"])
        if "content" not in result:
            if "not found" in str(result.get("msg", "")).lower():
                continue
            raise AnsibleFilterError(
                f"Could not read persisted hw-vdf wrapper for board {board_id}: {result.get('msg')}"
            )
        text = base64.b64decode(result["content"]).decode("utf-8", "replace")
        entry = _parse_claim(text, board_id)
        if entry is not None:
            entries.append((result, entry))
    return entries


def _claimed(results: list[dict[str, Any]]) -> list[dict[str, Any]]:
    boards: list[dict[str, Any]] = []
    for _result, entry in _claim_entries(results):
        serial = entry["expected_serial"]
        for board in boards:
            if _same_serial(serial, board["expected_serial"]):
                message = f"Persisted wrappers claim the same board serial {serial}."
                raise AnsibleFilterError(message)
        boards.append(entry)
    return boards


def _claim_labels(results: list[dict[str, Any]]) -> list[str]:
    labels = []
    for result, _entry in _claim_entries(results):
        item = result["item"]
        if isinstance(item, dict) and item.get("label"):
            labels.append(item["label"])
    return labels


def _wrapper_serial(content: str) -> str | None:
    text = base64.b64decode(content).decode("utf-8", "replace")
    return _last(text, "SERIAL")


def _visible_serials(client: dict[str, Any]) -> list[str]:
    if client.get("rc") != 0:
        return []
    serials = []
    for line in (client.get("stderr") or "").splitlines():
        if line.startswith(_DEVICE):
            row = _ROW.match(line)
            if row:
                serials.append(row.group(2))
    return serials


def _hidden_takeover(
    results: list[dict[str, Any]],
    labels: list[str],
    client: dict[str, Any],
) -> list[str]:
    wanted = set(labels)
    visible = _visible_serials(client)
    hidden = []
    for result in results:
        item = result.get("item")
        if not isinstance(item, dict) or item.get("label") not in wanted:
            continue
        if "content" not in result:
            continue
        serial = _wrapper_serial(result["content"])
        if not serial:
            hidden.append(f"{item['label']} (no SERIAL)")
        elif not any(_matches(serial, seen) for seen in visible):
            hidden.append(f"{item['label']} ({serial})")
    return hidden


def _stale(boards: list[dict[str, Any]]) -> str:
    return ", ".join(
        f"slot {b['id']} still claims serial "
        f"{b['expected_serial']} at the recorded loc {b['device_loc']} in its wrapper"
        for b in boards
    )


def _check_locations(boards: list[dict[str, Any]], hidden_ids: set[int]) -> None:
    for b in boards:
        loc = b["device_loc"]
        stale = [o for o in boards if o["id"] in hidden_ids and o["device_loc"] == loc]
        if b["id"] in hidden_ids:
            stale.remove(b)
        if stale:
            raise AnsibleFilterError(
                f"Auto-discovery found {b['expected_serial']} at loc "
                f"{b['device_loc']}, but {_stale(stale)}. Set "
                "chia_darwin_hw_vdf_boards explicitly to retire the stale claim."
            )


def merge_boards(
    client: dict[str, Any],
    wrappers: list[dict[str, Any]],
    pattern: str,
    client_path: str,
    slots: list[int],
) -> list[dict[str, Any]]:
    """Keep claimed IDs, refresh visible locations, and assign new serials free IDs."""
    text = client.get("stderr") or ""
    if client["rc"] != 0:
        raise AnsibleFilterError(
            f"Auto-discovery needs {client_path} --list, but failed "
            f"(rc {client['rc']}): {(text or client.get('msg', '')).strip()}"
        )
    rows = [_ROW.match(line) for line in text.splitlines() if line.startswith(_DEVICE)]
    if "List of available devices:" not in text or not all(rows):
        text = text.strip()
        raise AnsibleFilterError(f"Could not parse {client_path} --list: {text}")
    chia = [(row[2], int(row[1])) for row in rows if row and re.match(pattern, row[2])]
    visible = dict(chia)
    if len(visible) != len(chia):
        raise AnsibleFilterError("Auto-discovery found a duplicate Chia board serial.")
    claimed = _claimed(wrappers)
    hidden: list[dict[str, Any]] = []
    for board in claimed:
        # A wrapper stores the printed serial or its base, never a longer serial.
        full = next(
            (serial for serial in visible if _is_expected(board, serial)),
            None,
        )
        if full is None:
            hidden.append(board)
        else:
            board["device_loc"] = visible.pop(full)
    if not claimed and not visible:
        raise AnsibleFilterError(_NO_BOARDS)
    if len(claimed) + len(visible) > len(slots):
        stale = ""
        if hidden:
            stale = f" {_stale(hidden)}. Those persisted claims are not in --list."
        raise AnsibleFilterError(
            f"Auto-discovery found {len(claimed) + len(visible)} boards via {client_path} "
            f"--list; this role supports 1 to at most {len(slots)}.{stale} Set "
            "chia_darwin_hw_vdf_boards explicitly to retire a stale claim."
        )
    boards = claimed + [
        {"id": board_id, "device_loc": visible[serial], "expected_serial": serial}
        for board_id, serial in zip(
            sorted(set(slots) - {board["id"] for board in claimed}),
            sorted(visible),
        )
    ]
    _check_locations(boards, {board["id"] for board in hidden})
    return sorted(boards, key=lambda board: board["id"])


class FilterModule:  # pylint: disable=too-few-public-methods
    """Expose the board merge, claim, and takeover filters to Ansible."""

    def filters(self) -> dict[str, Callable[..., Any]]:
        """Return the filters provided by this plugin."""
        return {
            "chia_hw_vdf_merge_boards": merge_boards,
            "chia_hw_vdf_claims": _claimed,
            "chia_hw_vdf_claim_labels": _claim_labels,
            "chia_hw_vdf_hidden_takeover": _hidden_takeover,
        }
