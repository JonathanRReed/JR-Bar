"""Utility-generation policy: precedence, bounds, fallback."""

from jrbar.utility_generation import (
    TitleCache,
    accept_title,
    collect_evidence,
    should_generate,
)


def test_user_and_source_titles_block_generation():
    evidence = {"first_user_message": "rename the thing"}
    # A user-set title always wins — generation would fight it.
    assert should_generate("s1", "codex", has_user_title=True,
                           has_source_title=False, generated_before=False,
                           explicit=False, evidence=evidence) is None
    # The provider's own title also wins.
    assert should_generate("s1", "codex", has_user_title=False,
                           has_source_title=True, generated_before=False,
                           explicit=False, evidence=evidence) is None


def test_once_per_thread_and_explicit_regeneration():
    evidence = {"first_user_message": "fix the bug"}
    # First generation allowed when nothing real names the session.
    req = should_generate("s1", "codex", has_user_title=False,
                          has_source_title=False, generated_before=False,
                          explicit=False, evidence=evidence)
    assert req is not None and req.reason == "missing_label"
    # Second pass is refused — once per thread.
    assert should_generate("s1", "codex", has_user_title=False,
                           has_source_title=False, generated_before=True,
                           explicit=False, evidence=evidence) is None
    # An explicit ask overrides the once-per-thread rule.
    regen = should_generate("s1", "codex", has_user_title=False,
                            has_source_title=False, generated_before=True,
                            explicit=True, evidence=evidence)
    assert regen is not None and regen.reason == "explicit_regeneration"


def test_no_evidence_never_generates():
    assert should_generate("s1", "codex", has_user_title=False,
                           has_source_title=False, generated_before=False,
                           explicit=False, evidence={}) is None


def test_evidence_is_bounded_and_message_only():
    big = "x" * 5000
    evidence = collect_evidence("s1", "codex", first_user_message=big)
    assert len(evidence["first_user_message"]) == 500
    # Whitespace collapses; non-strings drop out.
    messy = collect_evidence("s1", "codex",
                             first_user_message="  hello\n\n world  ",
                             last_assistant_message=42)
    assert messy == {"first_user_message": "hello world"}


def test_accept_title_rejects_garbage():
    assert accept_title("  Fix the flaky test  ", had_label=False) == "Fix the flaky test"
    assert accept_title("", had_label=False) is None
    assert accept_title("   ", had_label=False) is None
    assert accept_title(None, had_label=True) is None
    assert accept_title("x" * 200, had_label=False) is not None  # truncated to 80
    assert len(accept_title("x" * 200, had_label=False)) == 80
    assert accept_title("has\x00null", had_label=False) is None


def test_cache_is_once_per_session_and_bounded():
    cache = TitleCache(max_entries=3)
    cache.put("a", "first")
    cache.put("b", "second")
    cache.put("c", "third")
    cache.put("d", "fourth")  # evicts "a"
    assert cache.get("a") is None
    assert cache.get("d") == "fourth"
    assert len(cache) == 3
    cache.clear("d")
    assert cache.get("d") is None
