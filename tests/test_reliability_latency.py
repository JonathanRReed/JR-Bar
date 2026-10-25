"""Exercise the controller methods without starting an AppKit host."""
import ast
from pathlib import Path
from types import SimpleNamespace

from jrbar.reset_persistence import ResetPersistence

ROOT = Path(__file__).resolve().parents[1] / 'src' / 'jrbar'


def method(file, name, namespace):
    node = next(n for n in ast.walk(ast.parse((ROOT / file).read_text()))
                if isinstance(n, ast.FunctionDef) and n.name == name)
    node.decorator_list = []
    exec(compile(ast.Module(body=[node], type_ignores=[]), str(ROOT / file), 'exec'), namespace)
    return namespace[name]


def test_urgent_refresh_cancels_trailing_wait_but_chatter_stays_coalesced():
    now = [100.1]
    timers = []
    def timer(*args):
        result = SimpleNamespace(invalidated=False)
        result.invalidate = lambda: setattr(result, 'invalidated', True)
        timers.append(result)
        return result
    namespace = dict(time=SimpleNamespace(monotonic=lambda: now[0]), EVENT_COALESCE_SECONDS=.25,
                     _legacy=SimpleNamespace(NSTimer=SimpleNamespace(
                         scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_=timer)))
    refresh = method('_status_bar_production.py', 'refreshFromEvent_', namespace)
    calls = []
    target = SimpleNamespace(_last_event_refresh_at=100, refresh_=lambda _: calls.append(now[0]))
    refresh(target, None)
    assert not calls and len(timers) == 1
    target._event_refresh_urgent = True
    refresh(target, None)
    assert calls == [100.1] and timers[0].invalidated
    assert target._trailing_refresh_timer is None and target._production_force_refresh
    now[0] = 100.2
    refresh(target, None)
    assert calls == [100.1] and len(timers) == 2


def test_urgent_hint_is_not_lost_behind_already_queued_chatter():
    schedule = method('status_bar_legacy.py', 'schedule_event_refresh', {})
    calls = []
    target = SimpleNamespace(event_refresh_pending=False,
                             performSelectorOnMainThread_withObject_waitUntilDone_=lambda *args: calls.append(args))
    schedule(target)
    schedule(target, urgent=True)
    assert len(calls) == 1 and target._event_refresh_urgent


def test_persistence_deadline_replaces_later_delivery_timer():
    book = ResetPersistence()
    book.changed('final')
    revision = book.begin(now=100)
    book.complete(revision, succeeded=False, reason='refused_full', now=100)
    timers = []
    def timer(delay, selector):
        result = SimpleNamespace(delay=delay, invalidated=False)
        result.invalidate = lambda: setattr(result, 'invalidated', True)
        timers.append(result)
        return result
    namespace = dict(ResetDeliveryState=lambda: None, next_reset_retry_delay=lambda *args, **kw: 15)
    schedule = method('provider_usage_status_bar.py', '_schedule_reset_delivery_retry', namespace)
    prior = timer(15, '')
    target = SimpleNamespace(_jrbar_reset_delivery_timer=prior, _jrbar_reset_delivery_retry_at=115,
                             _reset_persistence=lambda: book, _schedule_capacity_timer=timer)
    schedule(target, 100)
    assert prior.invalidated and timers[-1].delay == 1
    # No delivery work remains, but the failed final receipt still owns a wake.
    namespace['next_reset_retry_delay'] = lambda *args, **kw: None
    schedule(target, 100)
    assert target._jrbar_reset_delivery_timer is timers[-1]
