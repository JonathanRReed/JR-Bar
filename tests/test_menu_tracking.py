from __future__ import annotations

from dataclasses import replace

from AppKit import NSMenuItem, NSView

from jrbar.menu_tracking import (
    ExactBoundarySchedule,
    MenuItemState,
    MenuPublicationKind,
    StableNativeMenuRegistry,
    plan_menu_publication,
)
from jrbar.navigation_policy import OperatorActionKind


def _item(
    key: str,
    *,
    order: int = 0,
    parent: str | None = None,
    submenu: str | None = None,
    action: OperatorActionKind | None = None,
    title: str = "Agent",
    width: int = 80,
    height: int = 22,
) -> MenuItemState:
    return MenuItemState(
        item_key=key,
        parent_key=parent,
        order=order,
        submenu_key=submenu,
        action_kind=action,
        key_equivalent="",
        title=title,
        enabled=True,
        state=0,
        measured_width=width,
        measured_height=height,
        accessibility_label="Agent row",
        accessibility_value="Active",
        accessibility_help="Open actions",
    )


def test_identical_menu_has_no_publication__and_2_more() -> None:
    # --- scenario: identical_menu_has_no_publication
    row = _item("row")
    publication = plan_menu_publication((row,), (row,), tracking=True)

    assert publication.kind is MenuPublicationKind.NO_CHANGE
    assert publication.patches == ()

    # --- scenario: non_geometric_copy_and_state_patch_in_place
    before = _item("row", title="Agent 9m")
    after = replace(
        before,
        title="Agent 8m",
        enabled=False,
        state=1,
        accessibility_value="Eight minutes remaining",
        accessibility_help="Waiting for a fresh source",
    )

    publication = plan_menu_publication((before,), (after,), tracking=True)

    assert publication.kind is MenuPublicationKind.PATCH_IN_PLACE
    assert publication.patches == (after,)

    # --- scenario: title_geometry_change_defers_instead_of_moving_highlighted_row
    before = _item("row", title="9m", width=20)
    after = replace(before, title="10m", measured_width=28)

    publication = plan_menu_publication((before,), (after,), tracking=True)

    assert publication.kind is MenuPublicationKind.DEFER_REBUILD
    assert publication.patches == ()



def test_each_structural_change_defers_during_tracking__and_2_more() -> None:
    # --- scenario: each_structural_change_defers_during_tracking
    first = _item("first", order=0, submenu="actions")
    second = _item("second", order=1)
    structural_variants = (
        (first,),
        (first, second, _item("inserted", order=2)),
        (replace(first, order=1), replace(second, order=0)),
        (replace(first, submenu_key="replacement"), second),
        (replace(first, action_kind=OperatorActionKind.OPEN), second),
        (replace(first, parent_key="other"), second),
        (replace(first, key_equivalent="o"), second),
        (replace(first, measured_height=24), second),
        (replace(first, accessibility_label="Different row"), second),
    )

    for current in structural_variants:
        publication = plan_menu_publication((first, second), current, tracking=True)
        assert publication.kind is MenuPublicationKind.DEFER_REBUILD
        assert publication.patches == ()

    # --- scenario: one_hundred_row_copy_burst_patches_without_reordering
    previous = tuple(_item(f"row:{index}", order=index) for index in range(100))
    current = tuple(
        replace(row, title=f"Agent {index}", accessibility_value=f"Row {index}") for index, row in enumerate(previous)
    )

    publication = plan_menu_publication(previous, current, tracking=True)

    assert publication.kind is MenuPublicationKind.PATCH_IN_PLACE
    assert publication.patches == current

    # --- scenario: exact_boundary_schedule_rejects_early_and_stale_callbacks
    schedule = ExactBoundarySchedule()
    first = schedule.replace(101.25)
    second = schedule.replace(102.5)

    assert schedule.callback_due(first, now_epoch=103.0) is False
    assert schedule.callback_due(second, now_epoch=102.49) is False
    assert schedule.callback_due(second, now_epoch=102.5) is True
    assert schedule.callback_due(second, now_epoch=104.0) is False



def test_exact_next_copy_boundary_is_preserved_without_bucket_rounding__and_2_more() -> None:
    # --- scenario: exact_next_copy_boundary_is_preserved_without_bucket_rounding
    schedule = ExactBoundarySchedule()
    token = schedule.replace(1_800_000_012.345678)

    assert token.deadline_epoch == 1_800_000_012.345678
    assert schedule.deadline_epoch == 1_800_000_012.345678

    # --- scenario: native_registry_patches_real_item_without_replacing_highlighted_identity
    before = _item("row", title="Agent 9m")
    after = replace(before, title="Agent 8m", state=1)
    native = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(before.title, None, "")
    registry = StableNativeMenuRegistry()
    registry.install((before,), {"row": native})

    publication = registry.publish((after,), tracking=True)

    assert publication.kind is MenuPublicationKind.PATCH_IN_PLACE
    assert registry.item_for_key("row") is native
    assert native.title() == "Agent 8m"
    assert native.state() == 1

    # --- scenario: native_registry_defers_custom_view_copy_and_coalesces_latest_rebuild
    before = _item("row", title="Agent 9m")
    native = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(before.title, None, "")
    native.setView_(NSView.alloc().init())
    registry = StableNativeMenuRegistry()
    registry.install((before,), {"row": native})

    first = (replace(before, title="Agent 8m"),)
    latest = (replace(before, title="Agent 7m"),)
    assert registry.publish(first, tracking=True).kind is MenuPublicationKind.DEFER_REBUILD
    assert registry.publish(latest, tracking=True).kind is MenuPublicationKind.DEFER_REBUILD
    assert native.title() == "Agent 9m"
    assert registry.take_deferred_after_close() == latest
    assert registry.take_deferred_after_close() is None



def test_native_registry_defers_geometry_change_and_preserves_item_identity() -> None:
    before = _item("row", title="9m", width=20)
    after = replace(before, title="10m", measured_width=28)
    native = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(before.title, None, "")
    registry = StableNativeMenuRegistry()
    registry.install((before,), {"row": native})

    publication = registry.publish((after,), tracking=True)

    assert publication.kind is MenuPublicationKind.DEFER_REBUILD
    assert registry.item_for_key("row") is native
    assert native.title() == "9m"
