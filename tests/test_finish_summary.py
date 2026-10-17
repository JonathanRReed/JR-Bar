"""The line a finish banner says about what the agent just did."""

from __future__ import annotations

from types import SimpleNamespace

from jrbar.finish_summary import SUMMARY_LIMIT, finish_summary, summaries_for_finished


def test_the_first_real_line_wins_and_markdown_is_stripped() -> None:
    message = "\n\n## Done\n\n**Fixed** the `parse_row` bug in [the docs](https://example.test/x).\nMore."
    assert finish_summary(message) == "Done"
    assert (
        finish_summary("- [x] **Fixed** the `parse_row` bug in [the docs](https://example.test/x).")
        == "Fixed the parse_row bug in the docs."
    )
    assert finish_summary("> 3. Added __init__ and my_var") == "Added __init__ and my_var"


def test_fences_rules_and_blank_lines_are_skipped() -> None:
    message = "```\nrm -rf build\n```\n---\n\n| a | b |\n|---|---|\n"
    assert finish_summary("```\nrm -rf build\n```\n---\n\nAll tests pass.") == "All tests pass."
    assert finish_summary("```\nonly code\n```") is None
    assert finish_summary(message) == "| a | b |"


def test_nothing_in_nothing_out() -> None:
    for empty in (None, "", "   \n\t", 42, b"bytes"):
        assert finish_summary(empty) is None


def test_secret_looking_tokens_never_reach_the_line() -> None:
    token = "sk-" + "a1B2c3D4e5F6g7H8i9J0" * 3
    line = finish_summary(f"Rotated the key {token} and updated the vault")
    assert line is not None
    assert token not in line
    assert "[removed]" in line
    assert finish_summary("api_key=hunter2hunter2 was set") == "[removed] was set"
    assert finish_summary("Authorization: Bearer abc.def.ghi") is None
    long_run = "A" * 40
    assert long_run not in (finish_summary(f"see {long_run} here") or "")


def test_a_line_of_nothing_but_scrubbed_material_is_skipped() -> None:
    token = "ghp_" + "x" * 30
    assert finish_summary(f"{token}\nThe build is green.") == "The build is green."


def test_the_line_is_capped_on_a_word_boundary() -> None:
    line = finish_summary("word " * 100)
    assert line is not None
    assert len(line) <= SUMMARY_LIMIT
    assert line.endswith("…")
    assert not line[:-1].endswith(" ")
    assert finish_summary("x" * 20, limit=10) == "x" * 9 + "…"


def test_control_characters_become_spaces() -> None:
    assert finish_summary("Done\x1b[31m red\x00 text") == "Done red text"


def test_only_a_stop_with_a_message_is_quoted() -> None:
    def status(agent_id: str, event: str, message: str | None) -> SimpleNamespace:
        return SimpleNamespace(agent_id=agent_id, event_name=event, message=message)

    quoted = summaries_for_finished(
        [
            status("a", "Stop", "## Shipped\nDetails"),
            status("b", "Notification", "Claude is waiting for your input"),
            status("c", "Stop", None),
            status("d", "Stop", "```\ncode only\n```"),
        ]
    )
    assert quoted == {"a": "Shipped"}
