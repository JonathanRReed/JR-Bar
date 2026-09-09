"""Portable completion fixtures. Native/hardware verification is a separate gate."""
from dataclasses import replace
from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from jrbar.creator_micro_discovery import preferred_endpoints
from jrbar.creator_micro_lighting import CreatorMicroLightFrame, creator_micro_session_frame
from jrbar.deck_actions import DeckAction
from jrbar.deck_actions_macos import MacDeckActionExecutor
from jrbar.deck_control_settings import DeckControlSettings, decode_deck_controls
from jrbar.deck_input import ControlInput, DeckInputRouter
from jrbar.deck_input_dispatch import DeckInputDispatch
from jrbar.deck_session_board import DeckSessionBoard, session_identity
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey
from jrbar.surface_placement import SurfacePlacement

NOW = datetime(2026, 9, 6, tzinfo=timezone.utc)


def status(account="account-a", session="session-a", mode=AgentMode.WORKING):
    return AgentStatus(provider="codex", agent_id="codex:" + session, display_name=session,
                       mode=mode, updated_at=NOW, event_name="UserPromptSubmit",
                       work_key=WorkKey(SourceKey("codex", "native", account, "threads"), WorkIdentifier(session)))


def test_slot_identity_is_account_scoped_and_never_silently_reassigned():
    board = DeckSessionBoard(clock=lambda: NOW)
    a, b = status(), status("account-b")
    assert session_identity(a) != session_identity(b)
    board.update([a])
    first = board.resolve_slot(0)
    board.update([b])
    assert board.resolve_slot(0)[1] == first[1]
    assert board.snapshot().slots[0].state == "unavailable"
    assert board.snapshot().slots[1].identity == session_identity(b)
    board.clear_inactive()
    assert board.resolve_slot(0)[1] == session_identity(b)
    assert board.navigation_target(first[1], first[0]) is None


def test_status_does_not_grant_navigation_and_old_bank_revision_is_revoked():
    board = DeckSessionBoard(clock=lambda: NOW)
    a = status()
    identity = session_identity(a)
    board.update([a])
    revision, _ = board.resolve_slot(0)
    assert board.navigation_target(identity, revision) is None
    board.update([a], navigation_keys={identity})
    assert board.navigation_target(identity, revision) is a
    board.change_bank(1)
    assert board.navigation_target(identity, revision) is None
    board.update([replace(a, stale=True)], navigation_keys={identity})
    assert not board.snapshot().slots[0].navigable


def test_pins_survive_explicit_absent_clear_and_serialize_only_opaque_ids():
    board = DeckSessionBoard(clock=lambda: NOW)
    a = status(session="private-project-session")
    board.update([a])
    board.toggle_pin(0)
    board.update([])
    board.clear_inactive()
    assert board.snapshot().slots[0].pinned
    raw = board.serialize()
    assert "private-project" not in repr(raw)
    restored = DeckSessionBoard(clock=lambda: NOW)
    restored.restore(raw)
    assert restored.resolve_slot(0)[1] == session_identity(a)


def test_per_session_light_frames_keep_unknown_and_unassigned_slots_off():
    board = DeckSessionBoard(clock=lambda: NOW)
    board.update([status()])
    frame = creator_micro_session_frame(board.snapshot())
    assert frame.params()[0]["b"] > 0
    assert all(entry["b"] == 0 for entry in frame.params()[1:])
    board.update([replace(status(), stale=True)])
    assert creator_micro_session_frame(board.snapshot()).params()[0]["b"] == 0
    with pytest.raises(ValueError):
        CreatorMicroLightFrame(0, float("nan"), 1)


def test_analog_excursion_needs_recenter_and_never_accepts_nan():
    router = DeckInputRouter(analog_enabled=True)
    def message(angle, distance):
        return {"method": "v.oai.rad", "params": {"a": angle, "d": distance}}
    assert router.normalize(message(0, .8)).index == 20
    assert router.normalize(message(.25, .8)) is None
    assert router.normalize(message(.25, .1)) is None
    assert router.normalize(message(.25, .8)).index == 21
    router.reset()
    assert router.normalize(message(float("nan"), .8)) is None
    assert DeckInputRouter().normalize(message(0, .8)) is None


def test_normalized_user_inputs_are_fifo_and_reset_revokes_pending_work():
    calls, executed = [], []
    target = SimpleNamespace(performSelectorOnMainThread_withObject_waitUntilDone_=lambda _, batch, __: calls.append(batch))
    settings = DeckControlSettings(enabled=True, bindings=((3, DeckAction("open_usage")),))
    dispatch = DeckInputDispatch(target, settings)
    dispatch.receive_normalized((ControlInput(3, "press"), ControlInput(3, "press")))
    executor = MacDeckActionExecutor(open_usage=lambda: executed.append("usage"))
    assert len(calls) == 1
    dispatch.deliver(calls[0], executor)
    assert len(calls) == 2 and executed == ["usage"]
    dispatch.reset_connection()
    assert dispatch.deliver(calls[1], executor) == ()
    assert executed == ["usage"]


def test_legacy_mappings_migrate_and_duplicate_json_is_refused():
    assert decode_deck_controls('{"version":1,"enabled":false,"bindings":[]}') == DeckControlSettings()
    with pytest.raises(ValueError, match="duplicate"):
        decode_deck_controls('{"version":1,"enabled":false,"enabled":true,"bindings":[]}')
    action = DeckAction("run_system_shortcut", shortcut_name="Open editor")
    assert DeckAction.from_dict(action.to_dict()) == action
    with pytest.raises(ValueError):
        DeckAction("run_system_shortcut", shortcut_name="--help")


def test_usb_preference_only_collapses_proven_cross_transport_duplicate():
    usb = {"serial_number": "CM-1", "bus_type": 1, "path": "usb"}
    bt = {"serial_number": "CM-1", "bus_type": 2, "path": "bt"}
    assert preferred_endpoints([bt, usb]) == [usb]
    assert len(preferred_endpoints([usb, {**usb, "path": "ambiguous"}])) == 2


@pytest.mark.parametrize("edge", ["left", "right", "top", "bottom"])
def test_single_edge_transform_includes_inward_hit_regions(edge):
    placement = SurfacePlacement(edge, 420, 34)
    (x, y), (width, height) = placement.rect(40, 2, 30, 28)
    along, across = placement.inverse(x + width / 2, y + height / 2)
    assert (along, across) == (55, 16)
    (_, _), size = placement.frame(((0, 0), (1920, 1080)))
    assert size == placement.size
    with pytest.raises(ValueError):
        placement.rect(419, 0, 10, 5)


def test_composite_bluetooth_promotion_never_reclassifies_usb_keyboard(monkeypatch):
    from jrbar.creator_micro_hidapi import HidApiTransport
    rows = [
        {"vendor_id": 0x303A, "product_id": 0x8297, "serial_number": "CM-1", "bus_type": 1,
         "usage_page": 1, "usage": 6, "path": "usb-keyboard"},
        {"vendor_id": 0x303A, "product_id": 0x8297, "serial_number": "CM-1", "bus_type": 1,
         "usage_page": 0xFF00, "usage": 1, "path": "usb-vendor"},
        {"vendor_id": 0x303A, "product_id": 0x8297, "serial_number": "CM-1", "bus_type": 2,
         "usage_page": 1, "usage": 6, "path": "bt-composite"},
    ]
    monkeypatch.setattr("jrbar.creator_micro_hidapi.sys.platform", "darwin")
    monkeypatch.setattr("jrbar.creator_micro_discovery.native_vendor_collections",
                        lambda: frozenset({(0x303A, 0x8297, "CM-1", 1), (0x303A, 0x8297, "CM-1", 2)}))
    transport = HidApiTransport(SimpleNamespace(enumerate=lambda _: rows))
    assert [row["path"] for row in transport.enumerate()] == ["usb-vendor"]
