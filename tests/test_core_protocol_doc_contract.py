"""docs/CORE-PROTOCOL.md is the contract, so it has to keep up with the daemon.

A new command or field goes into the doc first (AGENTS.md). These checks read
the doc as text and compare it with what the daemon registers, so a command or
a field that ships without its entry fails here instead of drifting quietly.
"""

from __future__ import annotations

import re
from pathlib import Path

from jrbar import core_runtime

DOC = Path(__file__).resolve().parents[1] / "docs" / "CORE-PROTOCOL.md"


def _doc() -> str:
    return DOC.read_text(encoding="utf-8")


def _names(text: str, token: str) -> bool:
    """Whether `token` appears as a backticked word, however it is punctuated."""
    return re.search("`" + re.escape(token) + r"\b", text) is not None


def _names_field(text: str, token: str) -> bool:
    """Like `_names`, but a field may be named by its path: `usage.providers[].incident`."""
    return re.search(r"`(?:[\w-]+(?:\[\])?\.)*" + re.escape(token) + r"\b", text) is not None


def _section(doc: str, heading: str) -> str:
    """The text from `heading` to the next same-level heading."""
    start = doc.index(heading)
    end = doc.find("\n### ", start + len(heading))
    return doc[start:] if end < 0 else doc[start:end]


def _row(doc: str, command: str) -> str:
    """The command table row that starts with `command`."""
    prefix = f"| `{command}` |"
    rows = [line for line in doc.splitlines() if line.startswith(prefix)]
    assert len(rows) == 1, f"expected one command table row for {command}, found {len(rows)}"
    return rows[0]


def test_every_registered_command_is_named_in_the_protocol_doc() -> None:
    names = core_runtime.command_names()
    assert names, "the daemon registered no commands"
    doc = _doc()
    missing = [name for name in names if not _names(doc, name)]
    assert missing == [], f"commands the daemon answers but CORE-PROTOCOL.md never names: {missing}"


def test_the_deck_settings_row_names_its_ownership_arguments() -> None:
    row = _row(_doc(), "deck_set_settings")
    missing = [token for token in ("ownership", "layer_owners") if not _names(row, token)]
    assert missing == [], f"the deck_set_settings row does not name: {missing}"


def test_the_state_section_names_the_fields_the_daemon_sends() -> None:
    state = _section(_doc(), "### state (full)")
    fields = ("incident", "ownership", "layer_owners", "owner", "axes")
    missing = [token for token in fields if not _names_field(state, token)]
    assert missing == [], f"the state section does not name: {missing}"
