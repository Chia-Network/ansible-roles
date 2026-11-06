"""Merge hw_vdf_client --list output with the role's persisted wrappers."""

from __future__ import annotations

import base64
import re
from collections.abc import Callable
from typing import Any

from ansible.errors import AnsibleFilterError

_ROLE_MARKER = "# Managed by the chia-blockchain Ansible role."
_HEADER = "List of available devices:"
_DEVICE_LINE = re.compile(r"^Device [0-9]+:")
_DEVICE_ROW = re.compile(r"^Device [0-9]+: '.*', loc ([0-9]+), serial '([^']*)'$")
_DEVICE_LOC_LINE = re.compile(r"^DEVICE_LOC\b", re.MULTILINE)
_ASSIGNMENT = {
    "SERIAL": re.compile(r"^SERIAL=(?:'([^']*)'|\"([^\"]*)\"|(\S*))\s*$", re.MULTILINE),
    "DEVICE_LOC": re.compile(
        r"^DEVICE_LOC=(?:'([^']*)'|\"([^\"]*)\"|(\S*))\s*$",
        re.MULTILINE,
    ),
}


def _assignment(text: str, name: str) -> str | None:
    """Return the last value assigned to name in text, if any."""
    matches = list(_ASSIGNMENT[name].finditer(text))
    if not matches:
        return None
    return next(group for group in matches[-1].groups() if group is not None)


def _read_wrapper(result: dict[str, Any]) -> str | None:
    """Return wrapper text, or None when the wrapper does not exist yet."""
    board_id = result.get("item")
    if "content" in result:
        try:
            return base64.b64decode(result["content"]).decode("utf-8", "replace")
        except (KeyError, TypeError, ValueError) as exc:
            raise AnsibleFilterError(
                f"Could not decode persisted hw-vdf wrapper for board {board_id}.",
            ) from exc
    message = str(result.get("msg") or "")
    if "file not found" in message.lower():
        return None
    detail = message or "no content returned"
    raise AnsibleFilterError(
        f"Could not read persisted hw-vdf wrapper for board {board_id}: {detail}.",
    )


def _board_id(result: dict[str, Any]) -> int:
    """Return the board ID associated with a wrapper slurp result."""
    try:
        return int(result["item"])
    except (KeyError, TypeError, ValueError) as exc:
        raise AnsibleFilterError(
            "Could not determine the board ID for a persisted hw-vdf wrapper.",
        ) from exc


def _wrapper_boards(
    results: list[dict[str, Any]] | None,
) -> dict[str, dict[str, int]]:
    """Return claimed boards keyed by serial from persisted wrappers."""
    boards: dict[str, dict[str, int]] = {}
    for result in results or []:
        if not isinstance(result, dict):
            raise AnsibleFilterError("Could not inspect a persisted hw-vdf wrapper.")
        text = _read_wrapper(result)
        if text is None or _ROLE_MARKER not in text:
            continue
        board_id = _board_id(result)
        serial = _assignment(text, "SERIAL")
        location = _assignment(text, "DEVICE_LOC")
        if not _DEVICE_LOC_LINE.search(text):
            continue
        if not serial or location is None or not location.isdigit():
            raise AnsibleFilterError(
                f"Persisted hw-vdf wrapper for board {board_id} has invalid SERIAL or DEVICE_LOC.",
            )
        if serial in boards:
            raise AnsibleFilterError(
                "Auto-discovery found duplicate claimed board serial "
                f"{serial} in {boards[serial]['id']} and {board_id}."
            )
        boards[serial] = {"id": board_id, "device_loc": int(location)}
    return boards


def _parse_visible(text: str, pattern: str, client_path: str) -> dict[str, int]:
    """Return visible Chia boards keyed by serial from --list output."""
    device_lines = [line for line in text.splitlines() if _DEVICE_LINE.match(line)]
    serial_re = re.compile(pattern)
    boards: dict[str, int] = {}
    for line in device_lines:
        match = _DEVICE_ROW.match(line)
        if not match:
            raise AnsibleFilterError(
                f"Could not parse {client_path} --list output. Expected "
                "\"Device N: '<description>', loc <id>, serial '<serial>'\" lines. "
                f"Output was: {text.strip()}"
            )
        location, serial = match.groups()
        if not serial_re.match(serial):
            continue
        expected = serial[:-1]
        if expected in boards:
            raise AnsibleFilterError(
                f"Auto-discovery found duplicate Chia board serial {expected}.",
            )
        boards[expected] = int(location)
    return boards


def _visible_boards(
    client: dict[str, Any],
    pattern: str,
    client_path: str,
) -> dict[str, int]:
    """Return visible Chia boards keyed by serial, or fail clearly."""
    try:
        rc = int(client.get("rc", 1))
    except (TypeError, ValueError):
        rc = 1
    stderr = client.get("stderr") or ""
    stdout = client.get("stdout") or ""
    if rc != 0:
        detail = (stderr or client.get("msg") or stdout or "").strip()
        raise AnsibleFilterError(
            f"Auto-discovery needs {client_path} --list, but it failed (rc {rc}): {detail}",
        )
    text = stderr if _HEADER in stderr else stdout
    if _HEADER not in text:
        raise AnsibleFilterError(
            f"Could not parse {client_path} --list output. Expected "
            "\"Device N: '<description>', loc <id>, serial '<serial>'\" lines. "
            f"Output was: {text.strip()}"
        )
    return _parse_visible(text, pattern, client_path)


def merge_boards(
    client: dict[str, Any],
    wrappers: list[dict[str, Any]] | None,
    pattern: str,
    client_path: str,
) -> list[dict[str, int | str]]:
    """Merge --list serials with claimed boards and assign stable IDs."""
    claimed = _wrapper_boards(wrappers)
    visible = _visible_boards(client, pattern, client_path)
    used_ids = {board["id"] for board in claimed.values()}
    merged: list[dict[str, int | str]] = [
        {
            "id": board["id"],
            "device_loc": visible.get(serial, board["device_loc"]),
            "expected_serial": serial,
        }
        for serial, board in claimed.items()
    ]
    free_ids = sorted({1, 2, 3} - used_ids)
    new_serials = sorted(set(visible) - set(claimed))
    for index, serial in enumerate(new_serials):
        if index < len(free_ids):
            board_id = free_ids[index]
        else:
            board_id = max(used_ids | {3}) + index - len(free_ids) + 1
        merged.append(
            {
                "id": board_id,
                "device_loc": visible[serial],
                "expected_serial": serial,
            }
        )
    return sorted(merged, key=lambda board: board["id"])


class FilterModule:  # pylint: disable=too-few-public-methods
    """Expose the board merge filter to Ansible."""

    def filters(self) -> dict[str, Callable[..., Any]]:
        """Return the filters provided by this plugin."""
        return {"chia_hw_vdf_merge_boards": merge_boards}
