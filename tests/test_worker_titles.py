"""Session titles and explicit groups are shared by state and the roster."""
import re
from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

from jrbar.core_projection import SessionExtras, project_session_rows
from jrbar.models import AgentMode, AgentStatus, ParentLink

NOW = 1_800_000_000.0
HEAD = "codex:session:aaaaaaaa-0000-4000-8000-000000000000"
CHILDREN = [f"codex:session:bbbbbbb{i}-0000-4000-8000-000000000000" for i in range(3)]


def status(key, *, head=None, ended=False):
    return AgentStatus(
        "codex", key, "Codex " + key.rsplit(":", 1)[-1],
        AgentMode.COMPLETED if ended else AgentMode.WORKING,
        datetime.fromtimestamp(NOW, timezone.utc), "Stop" if ended else "PreToolUse",
        session_id=key.rsplit(":", 1)[-1],
        parent_links=(ParentLink(key, head, "t3code", NOW),) if head else (),
    )


def project(rows):
    snapshot = SimpleNamespace(statuses=rows, stale_statuses=(), collected_at=datetime.fromtimestamp(NOW, timezone.utc))
    extras = {HEAD: SessionExtras(name="Sample project"), CHILDREN[0]: SessionExtras(name="Fix the caption")}
    return {row["id"]: row for row in project_session_rows(snapshot, extras_by_id=extras, now=NOW)[0]}


def test_titled_and_untitled_workers_share_the_group_title_with_stable_ordinals():
    rows = [status(HEAD), *(status(key, head=HEAD) for key in CHILDREN)]
    projected = project(rows)
    assert projected[CHILDREN[0]]["label"] == "Fix the caption"
    assert projected[CHILDREN[1]]["label"] == "Sample project worker 2"
    assert projected[CHILDREN[2]]["label"] == "Sample project worker 3"
    reordered = project(list(reversed(rows)))
    assert {key: row["label"] for key, row in projected.items()} == {key: row["label"] for key, row in reordered.items()}
    for row in projected.values():
        assert not re.search(r"\b[0-9a-fA-F]{8,}\b", row["label"])
        assert row["short_id"]


def test_worker_keeps_its_title_and_group_when_the_head_ended():
    projected = project([status(HEAD, ended=True), status(CHILDREN[0], head=HEAD), status(CHILDREN[1], head=HEAD)])
    assert projected[CHILDREN[0]]["label"] == "Fix the caption"
    assert projected[CHILDREN[1]]["label"] == "Sample project worker 2"
    assert projected[CHILDREN[1]]["parent"] == HEAD


def test_a_project_label_is_context_rather_than_a_worker_task():
    worker = replace(status(CHILDREN[1], head=HEAD), display_name="Sample project", cwd="/tmp/Sample project")
    assert project([status(HEAD), worker])[worker.agent_id]["label"] == "Sample project worker 1"


def test_notices_reuse_projected_worker_titles_without_reading_provider_files():
    from jrbar.core_runtime import build_headless_controller_class

    worker = status(CHILDREN[1], head=HEAD)
    controller = SimpleNamespace(
        _core_documents={"state": {"sessions": [{"id": worker.agent_id, "label": "Sample project worker 2"}]}},
        _core_extras={},
    )
    label = build_headless_controller_class()._core_label(controller, worker)
    assert label == "Sample project worker 2"
    controller._core_documents = {}
    controller._core_extras = {worker.agent_id: (0, SessionExtras(name="Review the parser"))}
    assert build_headless_controller_class()._core_label(controller, worker) == "Review the parser"
