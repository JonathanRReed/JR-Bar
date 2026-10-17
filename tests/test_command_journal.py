"""The command journal: persist-before-effect, idempotent receipts."""

import json

import pytest

from jrbar.command_journal import (
    STATUS_ACCEPTED,
    CommandJournal,
    CommandJournalError,
    new_command_id,
)


def test_begin_persists_before_effect(tmp_path):
    journal = CommandJournal.load(tmp_path)
    record = journal.begin("answer_ask", {"session": "s1"}, now=100.0)
    assert record.status == STATUS_ACCEPTED
    # The file already holds the intent — a crash here leaves evidence.
    on_disk = json.loads((tmp_path / "command-journal.json").read_text())
    assert on_disk["commands"][0]["command_id"] == record.command_id
    assert on_disk["commands"][0]["status"] == "accepted"


def test_settle_completed_writes_receipt(tmp_path):
    journal = CommandJournal.load(tmp_path)
    record = journal.begin("answer_ask", {"session": "s1"}, now=100.0)
    settled = journal.settle(record.command_id,
                             receipt={"answered": True}, now=105.0)
    assert settled.status == "completed"
    assert settled.settled_at == 105.0
    # A reload sees the same receipt — durability across restart.
    reloaded = CommandJournal.load(tmp_path)
    assert reloaded.get(record.command_id).receipt == {"answered": True}


def test_retry_replays_first_receipt(tmp_path):
    journal = CommandJournal.load(tmp_path)
    record = journal.begin("answer_ask", {"session": "s1"}, now=100.0)
    journal.settle(record.command_id, receipt={"answered": True}, now=101.0)
    # Re-settling a completed record returns the first receipt — never a
    # second effect.
    again = journal.settle(record.command_id,
                           receipt={"answered": False}, now=102.0)
    assert again.receipt == {"answered": True}
    # And re-beginning the same id is the same record, not a new command.
    rebegin = journal.begin("answer_ask", {"session": "s1"},
                            command_id=record.command_id, now=103.0)
    assert rebegin.status == "completed"


def test_reconcile_names_outcome_unknown(tmp_path):
    journal = CommandJournal.load(tmp_path)
    journal.begin("answer_ask", {"session": "s1"}, command_id="crashed", now=100.0)
    done = journal.begin("answer_ask", {"session": "s2"}, now=101.0)
    journal.settle(done.command_id, receipt={"ok": True}, now=102.0)
    out = journal.reconcile(now=103.0)
    assert out["outcome_unknown"] == ["crashed"]
    assert out["completed"] == 1


def test_journal_survives_corrupt_file(tmp_path):
    (tmp_path / "command-journal.json").write_text("not json")
    journal = CommandJournal.load(tmp_path)
    assert journal.reconcile()["commands"] == 0


def test_settle_needs_outcome(tmp_path):
    journal = CommandJournal.load(tmp_path)
    record = journal.begin("answer_ask", {}, now=100.0)
    with pytest.raises(CommandJournalError):
        journal.settle(record.command_id, now=101.0)
    with pytest.raises(CommandJournalError):
        journal.settle("nope", receipt={"ok": True}, now=101.0)


def test_command_ids_are_unique():
    assert new_command_id() != new_command_id()


def test_a_client_cannot_make_the_journal_store_an_oversized_command_id(tmp_path):
    journal = CommandJournal.load(tmp_path)
    huge = "x" * (1024 * 1024)
    record = journal.begin("answer_ask", {"session": "s1"}, command_id=huge, now=100.0)
    assert record.command_id != huge
    assert record.command_id.startswith("cmd-")
    assert (tmp_path / "command-journal.json").stat().st_size < 4096
    # An id a client could reasonably mint keeps its identity, so a retry replays.
    kept = journal.begin("answer_ask", {"session": "s1"}, command_id="client-retry-0001", now=101.0)
    assert kept.command_id == "client-retry-0001"
    assert journal.begin("answer_ask", {"session": "s1"}, command_id="client-retry-0001").command_id == kept.command_id
