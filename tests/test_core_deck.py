"""The Creator Micro 2 in the daemon: ``state.deck``, the ``deck_*``
commands, the ``deck_input`` / ``deck_receipt`` events, and the keymap
setup path against the fake device the setup tests use."""

from __future__ import annotations

import base64
import json
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import core_deck, core_runtime
from jrbar.core_deck import (
    SETUP_RECEIPT_MESSAGES,
    DeckSlotFacts,
    build_deck_document,
    control_label,
    device_document,
    input_kind,
    keymap_facts,
    plan_document,
    receipt_message,
    slot_color,
    transport_word,
)
from jrbar.core_runtime import command_names
from jrbar.core_server import CommandError
from jrbar.creator_micro_adapter import Receipt
from jrbar.creator_micro_keymap import keymap_digest, plan_keymap
from jrbar.deck_actions_macos import DeckActionReceipt
from jrbar.models import AgentMode, AgentStatus
from jrbar.provider_facts import SourceKey, WorkIdentifier, WorkKey
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)
from tests.test_creator_micro_setup import Device, keymap

REAL_THREAD = threading.Thread
DECK_COMMANDS = {
    "deck_press", "deck_pin", "deck_bank", "deck_rail", "deck_clear_absent", "deck_plan_keymap",
    "deck_apply_keymap", "deck_restore_keymap", "deck_approve_device", "deck_check_input", "deck_set_settings",
}
SERIAL = "D0CF130481EC"
NOW = datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)


def _status(session: str, mode: AgentMode = AgentMode.WORKING, *, provider: str = "codex") -> AgentStatus:
    return AgentStatus(
        provider=provider,
        agent_id=f"{provider}:session:{session}",
        display_name=f"jr-bar {session}",
        mode=mode,
        updated_at=datetime.now(timezone.utc),
        event_name="UserPromptSubmit",
        session_id=session,
        work_key=WorkKey(SourceKey(provider, "native", "account-a", "threads"), WorkIdentifier(session)),
    )


# --- the pure vocabulary ----------------------------------------------------


def test_receipt_sentences_are_the_python_apps_own() -> None:
    from jrbar import creator_micro_setup_controller

    assert receipt_message("keymap_verified") == "Creator Micro 2 stored keymap verified. Reconnect if needed, then check inputs."
    assert receipt_message("device_conflict") == "Close Input and other hardware controllers, then inspect again."
    assert receipt_message("device_conflict", source="output") == "Creator Micro 2 stopped after detecting conflicting device traffic."
    assert receipt_message("ready", source="output") == "Creator Micro 2 ready."
    assert receipt_message("reconnecting", source="output") == "Creator Micro 2: reconnecting."
    assert receipt_message("target_not_frontmost", source="action") == "Switch to the mapped app before using its shortcut."
    assert receipt_message("navigation_requested", source="action") == "Device action: navigation requested."
    assert receipt_message("setup_failed") == "Creator Micro 2: setup failed."
    # The legacy setup controller reads the same table, so the two cannot drift.
    assert creator_micro_setup_controller._preview_text.__module__ == "jrbar.creator_micro_setup_controller"
    assert set(SETUP_RECEIPT_MESSAGES) >= {"keymap_restored", "already_restored", "recovery_required", "cancelled"}


def test_control_labels_input_kinds_and_transports() -> None:
    assert control_label(0) == "Key 1" and control_label(12) == "Key 13"
    assert control_label(13) == "Encoder 1 input 1" and control_label(19) == "Joystick sector 4"
    assert control_label(20) == "Analog sector 1" and control_label(23) == "Analog sector 4"
    assert control_label(14, {14: "Encoder 1 input 2 (volume)"}) == "Encoder 1 input 2 (volume)"
    assert input_kind(3, "press") == "press"
    assert input_kind(3, "virtual_press") == "press"
    assert input_kind(14, "press") == "dial" and input_kind(14, "rotate") == "dial"
    assert input_kind(17, "press") == "joystick"
    assert input_kind(21, "axis_sector") == "analog"
    assert transport_word(1) == "usb" and transport_word(2) == "bluetooth" and transport_word(None) is None


def test_plan_document_carries_the_review_text_and_controls() -> None:
    plan = plan_keymap(keymap(), {"layer_index": 1, "profile_index": 0}, profile_index=0, layer_index=0)
    document = plan_document(plan)
    assert document["profile"] == 0 and document["layer"] == 0 and document["include_auxiliary"] is False
    assert document["changes"][0] == "Key 0: KC_A -> KV_OAI_AG00; replaces its normal keystroke with a JR-Bar device input."
    assert len(document["changes"]) == 13
    assert document["preview"].startswith("Selected profile 1, layer 1:\n\nKey 0: KC_A -> KV_OAI_AG00;")
    assert "Dial and joystick mappings stay unchanged." in document["preview"]
    assert document["controls"] == [{"index": index, "label": f"Key {index + 1}"} for index in range(13)]


def test_keymap_facts_read_the_backup_and_the_recovery_journal(tmp_path: Path) -> None:
    backup = tmp_path / "creator-micro-keymap-abc.json"
    assert keymap_facts(None).state == "stock"
    assert keymap_facts(backup).state == "stock"
    original = keymap()
    plan = plan_keymap(original, {"layer_index": 1, "profile_index": 0})
    backup.write_text(json.dumps({
        "version": 1, "device_key": "abc", "original_json": original, "proposed_json": plan.proposed_json,
        "original_digest": plan.original_digest, "proposed_digest": plan.proposed_digest,
    }))
    facts = keymap_facts(backup)
    assert facts.state == "stock" and facts.backup_at is not None and facts.original_json == original
    journal = backup.with_suffix(".recovery.json")

    def write_journal(state: str, after: str) -> None:
        journal.write_text(json.dumps({
            "version": 1, "device_key": "abc", "backup_digest": plan.original_digest,
            "before_base64": base64.b64encode(original.encode()).decode(), "after_json": after, "state": state, "max_prefix": 0,
        }))

    write_journal("pending", plan.proposed_json)
    assert keymap_facts(backup).state == "recovering"
    write_journal("verified", plan.proposed_json)
    assert keymap_facts(backup).state == "applied"
    write_journal("verified", original)
    assert keymap_facts(backup).state == "stock"
    assert keymap_digest(original) == plan.original_digest
    journal.write_text("not json")
    assert keymap_facts(backup).state == "unknown"
    backup.write_text("{}")
    assert keymap_facts(backup).state == "unknown"


def test_slot_colours_follow_the_lighting_layer() -> None:
    assert slot_color("input_required") == "#FF3A00"
    assert slot_color("failure") == "#FF3A00"
    assert slot_color("active") == "#00E5FF"
    assert slot_color("completed") == "#00FF66"
    for state in ("idle", "stale", "unavailable", "unknown", "ended_unconfirmed"):
        assert slot_color(state) == core_deck.DARK_COLOR
    assert slot_color("active", driven=False) == core_deck.OFF_COLOR
    assert slot_color("active", brightness=0.0) == core_deck.DARK_COLOR


def test_deck_document_has_the_shape_the_app_decodes() -> None:
    device = device_document(serial=SERIAL, transport="bluetooth", connected=True, approved=True, layer=0, profile=0,
                             receipt={"code": "ready", "message": "Creator Micro 2 ready.", "at": 1.0})
    document = build_deck_document(
        device=device,
        slots=[DeckSlotFacts(0, "a" * 64, "codex:session:x", "JR-Bar", "codex", "active", True, True), DeckSlotFacts(1, "b" * 64)]
        + [DeckSlotFacts(index) for index in range(2, 13)],
        bank=0, bank_count=1, rail_edge="left", keymap_state="applied", backup_at=2.0, keymap_generation=3,
        layers=[{"profile": 0, "layer": 0, "label": "Profile 1 / Layer 1: Base"}], input_check=False,
        last_input={"index": 2, "kind": "press", "at": 3.0},
        settings={"enabled": True, "session_mode": True, "analog_enabled": False},
        bindings={14: "next_bank"}, driven=True,
    )
    assert set(document) == {"device", "slots", "aux", "banks", "rail", "keymap", "input_check", "last_input", "settings"}
    assert set(document["device"]) == {"serial", "name", "transport", "connected", "approved", "firmware", "layer", "profile", "conflict", "receipt"}
    assert len(document["slots"]) == 13 and len(document["aux"]) == 7
    assert set(document["slots"][0]) == {"index", "identity", "session", "label", "provider", "state", "pinned", "navigable", "color"}
    assert document["slots"][0]["color"] == "#00E5FF" and document["slots"][1]["state"] == "unavailable"
    assert document["slots"][1]["color"] == core_deck.DARK_COLOR
    assert document["aux"][1] == {"index": 14, "label": "Encoder 1 input 2", "mapping": "next_bank"}
    assert document["keymap"] == {"state": "applied", "backup_at": 2.0, "generation": 3,
                                  "layers": [{"profile": 0, "layer": 0, "label": "Profile 1 / Layer 1: Base"}]}
    assert document["rail"] == {"edge": "left"} and document["banks"] == {"index": 0, "count": 1}
    assert build_deck_document(device=None, slots=[], bank=0, bank_count=0, rail_edge="sideways", keymap_state="weird",
                               backup_at=None, keymap_generation=0, layers=[], input_check=False, last_input=None,
                               settings={})["rail"] == {"edge": "off"}


# --- the daemon --------------------------------------------------------------


def _board_with(controller, statuses) -> None:
    """A loaded board fed by these statuses (the fixture's threads are inert)."""
    controller._core_deck_board()
    controller._deck_board_ready = True
    controller.monitor = SimpleNamespace(current_statuses_by_key=lambda: {status.agent_id: status for status in statuses})
    controller.last_snapshot = SimpleNamespace(statuses=tuple(statuses), stale_statuses=(), aggregate=None)


def _events(controller, kind: str) -> list[dict]:
    return [document for name, document in controller._core.published if name == "event" and document.get("kind") == kind]


def test_every_deck_command_is_registered() -> None:
    assert DECK_COMMANDS <= set(command_names())


def test_state_carries_the_deck_with_no_pad_and_with_an_unapproved_one(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    state = controller._core_build_state()
    deck = state["deck"]
    assert deck["device"] is None
    assert [slot["index"] for slot in deck["slots"]] == list(range(13))
    assert all(slot["state"] == "unavailable" and slot["identity"] is None for slot in deck["slots"])
    assert [row["index"] for row in deck["aux"]] == list(range(13, 20))
    assert deck["banks"] == {"index": 0, "count": 1} and deck["rail"] == {"edge": "off"}
    assert deck["keymap"] == {"state": "stock", "backup_at": None, "generation": 0, "layers": []}
    assert deck["input_check"] is False and deck["last_input"] is None
    assert deck["settings"] == {"enabled": False, "session_mode": False, "analog_enabled": False}
    # A pad the probe can see but nobody approved yet.
    controller._core_deck_devices = [{"serial_number": SERIAL, "bus_type": 2, "product_id": 0x8297}]
    device = controller._core_build_state()["deck"]["device"]
    assert device["serial"] == SERIAL and device["transport"] == "bluetooth"
    assert device["connected"] is True and device["approved"] is False and device["conflict"] is None
    assert device["name"] == "Creator Micro 2"
    controller._core_publish_state()
    doctor = controller._core_dispatch("doctor", {})
    assert doctor["devices"]["creator-micro"] == "connected"


def test_board_commands_pin_bank_rail_and_clear(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    live = [_status(f"session-{index:02d}") for index in range(15)]
    by_id = {status.agent_id: status for status in live}
    _board_with(controller, live)
    deck = controller._core_build_state()["deck"]
    assert deck["banks"] == {"index": 0, "count": 2}
    # New identities are appended in digest order; positions are stable from here on.
    first, second = deck["slots"][0], deck["slots"][1]
    assert first["session"] in by_id and first["state"] == "active" and first["navigable"] is False
    assert first["label"] == by_id[first["session"]].display_name and first["provider"] == "codex"
    assert first["color"] == core_deck.OFF_COLOR  # no output service: the pad is not driven
    assert sum(1 for slot in deck["slots"] if slot["session"]) == 13
    identity = first["identity"]

    assert controller._core_dispatch("deck_pin", {"index": 0}) == {"index": 0, "identity": identity, "pinned": True}
    assert controller._core_build_state()["deck"]["slots"][0]["pinned"] is True
    assert controller._core_dispatch("deck_pin", {"index": 0})["pinned"] is False
    with pytest.raises(CommandError) as bad:
        controller._core_dispatch("deck_pin", {"index": 13})
    assert bad.value.code == "invalid_args"

    assert controller._core_dispatch("deck_bank", {"delta": 1}) == {"index": 1, "count": 2}
    bank_two = controller._core_build_state()["deck"]["slots"]
    assert sum(1 for slot in bank_two if slot["session"]) == 2 and bank_two[0]["session"] not in (first["session"], second["session"])
    with pytest.raises(CommandError) as unassigned:
        controller._core_dispatch("deck_pin", {"index": 12})
    assert unassigned.value.code == "not_found" and unassigned.value.message == "No session assigned."
    assert controller._core_dispatch("deck_bank", {"delta": 1}) == {"index": 0, "count": 2}
    assert controller._core_dispatch("deck_bank", {"delta": -1}) == {"index": 1, "count": 2}
    assert controller._core_dispatch("deck_bank", {"delta": 3}) == {"index": 0, "count": 2}
    with pytest.raises(CommandError):
        controller._core_dispatch("deck_bank", {"delta": "up"})

    assert controller._core_dispatch("deck_rail", {"edge": "left"}) == {"edge": "left"}
    assert controller._core_build_state()["deck"]["rail"] == {"edge": "left"}
    with pytest.raises(CommandError) as edge:
        controller._core_dispatch("deck_rail", {"edge": "sideways"})
    assert edge.value.code == "invalid_args"

    # The first two sessions vanish: their keys read Reserved until an explicit clear.
    controller._core_dispatch("deck_pin", {"index": 1})
    _board_with(controller, [status for status in live if status.agent_id not in (first["session"], second["session"])])
    deck = controller._core_build_state()["deck"]
    assert deck["slots"][0]["state"] == "unavailable" and deck["slots"][0]["session"] is None
    assert deck["slots"][0]["identity"] == identity and deck["slots"][1]["pinned"] is True
    cleared = controller._core_dispatch("deck_clear_absent", {})
    assert cleared == {"removed": 1, "banks": {"index": 0, "count": 2}}
    deck = controller._core_build_state()["deck"]
    # The pinned reserved key stays where it was; the unpinned one left and later keys moved up.
    assert deck["slots"][0]["identity"] == second["identity"] and deck["slots"][0]["pinned"] is True
    assert deck["slots"][0]["session"] is None and deck["slots"][1]["session"] is not None
    assert sum(1 for slot in deck["slots"] if slot["session"]) == 12


def test_deck_press_reveals_answers_or_refuses(headless, monkeypatch: pytest.MonkeyPatch) -> None:  # noqa: F811
    from jrbar import deck_control_center
    from jrbar.deck_actions import DeckAction
    from jrbar.deck_control_settings import DeckControlSettings

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    live = [_status("session-a", AgentMode.WAITING_FOR_INPUT), _status("session-b")]
    _board_with(controller, live)
    slot_of = {slot["session"]: slot["index"] for slot in controller._core_build_state()["deck"]["slots"] if slot["session"]}
    ask_key, work_key = slot_of[live[0].agent_id], slot_of[live[1].agent_id]
    revealed: list[tuple[str, int | None]] = []
    monkeypatch.setattr(
        deck_control_center, "reveal_deck_session",
        lambda target, identity, revision: revealed.append((identity, revision)) or DeckActionReceipt("navigation_requested", True),
    )
    answers: list[dict] = []

    def answer(self, args):
        answers.append(args)
        if args["session"].endswith("session-b"):
            raise CommandError("not_found", "no live ask for that session")
        if not getattr(controller, "_terminal_in_front", False):
            raise CommandError("not_frontmost", "the session's terminal is not in front")
        return {"session": args["session"], "decision": args["decision"], "answered": True}

    monkeypatch.setattr(core_runtime, "_cmd_answer_ask", answer)

    with pytest.raises(CommandError) as bad:
        controller._core_dispatch("deck_press", {"index": 24})
    assert bad.value.code == "invalid_args"
    with pytest.raises(CommandError) as empty:
        controller._core_dispatch("deck_press", {"index": 5})
    assert (empty.value.code, empty.value.message) == ("not_found", "No session assigned.")
    with pytest.raises(CommandError) as aux:
        controller._core_dispatch("deck_press", {"index": 14})
    assert (aux.value.code, aux.value.message) == ("not_found", "Configure this auxiliary control in Settings > Devices.")

    # A working session: reveal.
    reply = controller._core_dispatch("deck_press", {"index": work_key})
    assert reply["action"] == "reveal_session" and reply["session"] == live[1].agent_id and reply["receipt"] == "navigation_requested"
    assert revealed and revealed[-1][0] == reply["identity"]
    # A live ask whose terminal is not in front: reveal, never approve.
    reply = controller._core_dispatch("deck_press", {"index": ask_key})
    assert reply["action"] == "reveal_session" and answers[-1]["only_if_frontmost"] is True
    # The terminal is in front: the press answers the ask through answer_ask.
    controller._terminal_in_front = True
    reply = controller._core_dispatch("deck_press", {"index": ask_key})
    assert reply == {"index": ask_key, "identity": reply["identity"], "session": live[0].agent_id,
                     "action": "answer_ask", "decision": "approve", "answered": True}
    # Input check pauses every action.
    assert controller._core_dispatch("deck_check_input", {"enabled": True}) == {"enabled": True}
    assert controller._core_build_state()["deck"]["input_check"] is True
    with pytest.raises(CommandError) as paused:
        controller._core_dispatch("deck_press", {"index": ask_key})
    assert (paused.value.code, paused.value.message) == ("input_check", "Input check is on: device actions are paused.")
    controller._core_dispatch("deck_check_input", {"enabled": False})
    # An explicit mapping wins over the session key.
    controller._deck_control_settings = DeckControlSettings(True, ((ask_key, DeckAction("next_bank")), (14, DeckAction("open_usage"))), True)
    reply = controller._core_dispatch("deck_press", {"index": ask_key})
    assert reply["action"] == "next_bank" and reply["bank"] == {"index": 0, "count": 1} and reply["receipt"] == "bank_changed"
    assert controller._core_build_state()["deck"]["aux"][1]["mapping"] == "open_usage"
    # A reserved key (identity kept, session gone).
    _board_with(controller, live[1:])
    controller._deck_control_settings = None
    with pytest.raises(CommandError) as reserved:
        controller._core_dispatch("deck_press", {"index": ask_key})
    assert (reserved.value.code, reserved.value.message) == ("not_found", "Reserved: session not observed.")


def test_physical_inputs_become_events_and_state(headless) -> None:  # noqa: F811
    from jrbar.deck_control_settings import DeckControlSettings
    from jrbar.deck_input import ControlInput
    from jrbar.deck_input_dispatch import DeckInputDispatch

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    _board_with(controller, [_status("session-a")])
    controller._core_build_state()
    dispatch = DeckInputDispatch(controller, DeckControlSettings(True, (), True))
    controller._deck_input_check_active = True  # inputs are shown, actions paused
    dispatch.receive_normalized((ControlInput(2, "press"), ControlInput(14, "rotate"), ControlInput(21, "axis_sector")))
    inputs = _events(controller, "deck_input")
    assert [event["input"]["kind"] for event in inputs] == ["press", "dial", "analog"]
    assert [event["label"] for event in inputs] == ["Key 3", "Encoder 1 input 2", "Analog sector 2"]
    assert inputs[0]["input"]["index"] == 2 and abs(inputs[0]["input"]["at"] - time.time()) < 5.0
    deck = controller._core_build_state()["deck"]
    assert deck["last_input"]["index"] == 21 and deck["last_input"]["kind"] == "analog"
    # A physical session-key press goes through the same executor as the app's click.
    controller._deck_input_check_active = False
    delivered: list = []
    controller._core_deck_reveal_or_answer = lambda identity, revision: delivered.append(identity) or DeckActionReceipt("navigation_requested", True)
    controller.performSelectorOnMainThread_withObject_waitUntilDone_ = (
        lambda selector, payload, wait: controller.applyDeckInput_(payload)
    )
    dispatch.receive_normalized((ControlInput(0, "press"),))
    assert delivered == [controller._core_build_state()["deck"]["slots"][0]["identity"]]
    assert controller._deck_action_receipt.code == "navigation_requested"


def test_output_receipts_become_deck_receipt_events_and_the_conflict_flag(headless) -> None:  # noqa: F811
    from jrbar.optional_integration_runtime import CreatorMicroOutputReceipt

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    controller._core_deck_devices = [{"serial_number": SERIAL, "bus_type": 1, "product_id": 0x8297}]
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(True, "ready"))
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(True, "ready"))
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(False, "device_conflict", "foreign response"))
    receipts = _events(controller, "deck_receipt")
    assert [(event["code"], event["message"]) for event in receipts] == [
        ("ready", "Creator Micro 2 ready."),
        ("device_conflict", "Creator Micro 2 stopped after detecting conflicting device traffic."),
    ]
    device = controller._core_build_state()["deck"]["device"]
    assert device["conflict"] == "foreign_responses" and device["connected"] is True and device["transport"] == "usb"
    assert device["receipt"]["code"] == "device_conflict"
    controller.applyCreatorMicroOutputReceipt_(CreatorMicroOutputReceipt(False, "reconnecting"))
    assert controller._core_build_state()["deck"]["device"]["conflict"] is None
    assert _events(controller, "deck_receipt")[-1]["message"] == "Creator Micro 2: reconnecting."


# --- keymap setup against the fake device -----------------------------------


class _FakeAdapter(Device):
    """The setup tests' fake pad behind the adapter surface the setup
    controller expects (connect / close / conflict)."""

    conflict = SimpleNamespace(active=False)

    def __init__(self, serial: str) -> None:
        super().__init__()
        self.serial = serial

    def connect(self) -> Receipt:
        return Receipt("connected")

    def close(self) -> None:
        return None


class _FakeRuntime:
    def __init__(self, target) -> None:
        self.target = target
        self.closed = False
        self.published = 0
        self._deck_dispatch = None

    def revoke_deck_input(self) -> None:
        return None

    def close(self) -> None:
        self.closed = True

    def wait_until_stopped(self, timeout: float) -> bool:
        return True

    def publish_creator_output(self, mode, *, signal=None) -> bool:
        self.published += 1
        return True


@pytest.fixture
def deck_live(headless, monkeypatch: pytest.MonkeyPatch):  # noqa: F811
    """The daemon with real threads, an approved fake pad and an inert
    output runtime, so setup operations run end to end."""
    from jrbar import creator_micro_setup_controller, optional_integration_runtime
    from jrbar.integration_settings import IntegrationSettings, save_integration_settings

    monkeypatch.setattr(threading, "Thread", REAL_THREAD)
    devices: dict[str, _FakeAdapter] = {SERIAL: _FakeAdapter(SERIAL)}
    runtimes: list[_FakeRuntime] = []

    def start_runtime(target):
        runtime = _FakeRuntime(target)
        runtimes.append(runtime)
        return runtime

    monkeypatch.setattr(optional_integration_runtime, "start_optional_integration_runtime", start_runtime)
    monkeypatch.setattr(creator_micro_setup_controller, "_default_adapter_factory", lambda serial: devices[serial])
    monkeypatch.setattr(core_runtime, "deck_probe", lambda: [{"serial_number": SERIAL, "bus_type": 2, "product_id": 0x8297}])
    save_integration_settings(IntegrationSettings().with_creator_micro(enabled=True, device_serial=SERIAL))
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    controller._deck_board_ready = True

    def dispatch(selector: str, payload, wait: bool) -> bool:
        getattr(controller, selector.replace(":", "_"))(payload)
        return True

    controller.performSelectorOnMainThread_withObject_waitUntilDone_ = dispatch
    controller._core_deck_probe_now(wait=True)
    controller._deck_test_devices = devices
    controller._deck_test_runtimes = runtimes
    return controller


def test_plan_apply_and_restore_run_the_setup_path_without_alerts(deck_live) -> None:
    controller = deck_live
    device = controller._deck_test_devices[SERIAL]
    state = controller._core_build_state()["deck"]
    assert state["device"]["approved"] is True and state["device"]["connected"] is True
    assert state["keymap"]["state"] == "stock" and state["keymap"]["layers"] == []

    with pytest.raises(CommandError) as bad_plan:
        controller._core_dispatch("deck_plan_keymap", {"profile": "0", "layer": 0})
    assert (bad_plan.value.code, bad_plan.value.message) == ("invalid_plan", "invalid selected profile")

    plan = controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 0, "include_auxiliary": False})
    assert plan["changes"][0].startswith("Key 0: KC_A -> KV_OAI_AG00;")
    assert plan["preview"].startswith("Selected profile 1, layer 1:")
    assert device.writes == []  # inspection only reads
    assert controller._deck_test_runtimes[-1] is controller._jrbar_optional_integration_runtime  # the pad was handed back
    state = controller._core_build_state()["deck"]
    assert state["keymap"]["layers"] == [{"profile": 0, "layer": 0, "label": "Profile 1 / Layer 1: Layer 1"}]
    assert state["device"]["profile"] == 0 and state["device"]["layer"] == 0
    with pytest.raises(CommandError) as bad_layer:
        controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 4})
    assert (bad_layer.value.code, bad_layer.value.message) == ("invalid_plan", "invalid selected layer")

    applied = controller._core_dispatch("deck_apply_keymap", {"profile": 0, "layer": 0, "include_auxiliary": False})
    assert applied["code"] == "keymap_verified"
    assert applied["message"] == "Creator Micro 2 stored keymap verified. Reconnect if needed, then check inputs."
    assert len(applied["changes"]) == 13 and applied["state"] == "applied" and applied["backup_at"] is not None
    assert json.loads(device.raw)["profiles"][0]["layers"][0]["layout"]["keymap"][0] == ["KV_OAI_AG00", "KV_OAI_AG01"]
    state = controller._core_build_state()["deck"]
    assert state["keymap"]["state"] == "applied" and state["keymap"]["generation"] == applied["generation"]
    assert state["input_check"] is True  # a verified write opens the input check, as the Python app did
    assert state["device"]["receipt"]["code"] == "keymap_verified"
    receipts = [event["code"] for event in _events(controller, "deck_receipt")]
    assert receipts[-1] == "keymap_verified"

    again = controller._core_dispatch("deck_apply_keymap", {"profile": 0, "layer": 0})
    assert again["code"] == "already_configured" and again["message"] == "Creator Micro 2 keymap is already configured."

    restored = controller._core_dispatch("deck_restore_keymap", {})
    assert restored["code"] == "keymap_restored" and restored["state"] == "stock"
    assert device.raw == keymap()
    assert controller._core_dispatch("deck_restore_keymap", {})["code"] == "already_restored"
    assert controller._core_build_state()["deck"]["keymap"]["state"] == "stock"


def test_setup_refusals_are_error_replies_with_the_receipt_sentence(deck_live) -> None:
    from jrbar.integration_settings import IntegrationSettings, save_integration_settings

    controller = deck_live
    device = controller._deck_test_devices[SERIAL]
    # No private backup from an earlier test: the sandboxed config dir is shared.
    backup = controller._core_deck_backup_path(SERIAL)
    for path in (backup, backup.with_suffix(".recovery.json")):
        path.unlink(missing_ok=True)
    controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 0})
    device.raw = keymap().replace("KC_A", "KC_Z")  # the pad changed under the cached inspection
    with pytest.raises(CommandError) as changed:
        controller._core_dispatch("deck_apply_keymap", {"profile": 0, "layer": 0})
    assert changed.value.code == "keymap_changed"
    assert changed.value.message == "The device keymap changed. Inspect it again before applying."
    assert controller._core_build_state()["deck"]["device"]["receipt"]["code"] == "keymap_changed"
    with pytest.raises(CommandError) as no_backup:
        controller._core_dispatch("deck_restore_keymap", {})
    assert no_backup.value.code == "backup_invalid"
    assert no_backup.value.message == "No valid private backup is available. No keymap was written."
    save_integration_settings(IntegrationSettings())
    controller._core_deck_integration_cache = None
    controller._core_deck_inspection = None
    with pytest.raises(CommandError) as unapproved:
        controller._core_dispatch("deck_plan_keymap", {"profile": 0, "layer": 0})
    assert unapproved.value.code == "connection_required"
    assert unapproved.value.message == "Connect and approve Creator Micro 2 before setup."
    assert controller._core_build_state()["deck"]["device"]["approved"] is False


def test_approve_device_and_set_settings_persist_and_reconfigure(deck_live, monkeypatch: pytest.MonkeyPatch) -> None:
    from jrbar import creator_micro_hidapi
    from jrbar.deck_control_settings import load_deck_controls
    from jrbar.integration_settings import IntegrationSettings, load_integration_settings, save_integration_settings

    controller = deck_live
    save_integration_settings(IntegrationSettings())
    controller._core_deck_integration_cache = None
    assert controller._core_build_state()["deck"]["device"]["approved"] is False
    rows = [{"vendor_id": 0x303A, "product_id": 0x8297, "serial_number": SERIAL, "bus_type": 2, "usage_page": 0xFF00, "usage": 1}]
    monkeypatch.setattr(creator_micro_hidapi, "HidApiTransport", lambda *a, **k: SimpleNamespace(enumerate=lambda: rows))
    before = len(controller._deck_test_runtimes)
    assert controller._core_dispatch("deck_approve_device", {}) == {"serial": SERIAL, "approved": True}
    assert load_integration_settings().settings.creator_micro_device_serial == SERIAL
    assert controller._core_build_state()["deck"]["device"]["approved"] is True
    assert len(controller._deck_test_runtimes) > before  # the output service was reconfigured
    # With no pad in sight the remembered serial is not enabled blindly.
    rows.clear()
    monkeypatch.setattr(core_runtime, "deck_probe", lambda: [])
    save_integration_settings(IntegrationSettings().with_creator_micro(enabled=False, device_serial=SERIAL))
    controller._core_deck_integration_cache = None
    with pytest.raises(CommandError) as none:
        controller._core_dispatch("deck_approve_device", {})
    assert (none.value.code, none.value.message) == ("no_device", "No Creator Micro 2 is connected.")
    assert load_integration_settings().settings.creator_micro_enabled is False

    with pytest.raises(CommandError) as bad:
        controller._core_dispatch("deck_set_settings", {"enabled": "yes"})
    assert bad.value.code == "invalid_args"
    reply = controller._core_dispatch("deck_set_settings", {"enabled": True, "session_mode": True})
    assert reply == {"enabled": True, "session_mode": True, "analog_enabled": False}
    saved = load_deck_controls()
    assert saved.enabled is True and saved.session_mode is True and saved.analog_enabled is False
    assert controller._deck_control_settings == saved
    assert controller._core_build_state()["deck"]["settings"] == reply
    assert controller._core_dispatch("deck_set_settings", {"analog_enabled": True})["analog_enabled"] is True
