from jrbar.reset_persistence import ResetPersistence


def test_final_receipt_retries_without_delivery_work_and_stays_dirty_after_exhaustion():
    book = ResetPersistence()
    book.changed('final receipt')
    revision = book.begin(now=100)
    for failure_at, retry_at in [(100, 101), (101, 106), (106, 136)]:
        book.complete(revision, succeeded=False, reason='refused_full', now=failure_at)
        assert book.dirty and book.retry_at == retry_at
        assert book.begin(now=retry_at - .01) is None
        assert book.begin(now=retry_at) == revision
    book.complete(revision, succeeded=False, reason='write_failed', now=136)
    assert book.dirty and book.retry_at is None and book.retries == 3
    assert book.begin(now=10000) is None
    book.changed('final receipt', retry=True)
    assert book.begin(now=10000) == revision + 1


def test_old_completion_cannot_clear_new_revision():
    book = ResetPersistence()
    book.changed('old')
    old = book.begin(now=100)
    book.changed('new')
    new = book.begin(now=101)
    book.complete(old, succeeded=True, reason=None, now=102)
    assert book.dirty and book.in_flight and book.revision == new
    book.complete(new, succeeded=True, reason=None, now=103)
    assert not book.dirty and book.error is None and book.retry_at is None
    assert book.begin(now=200) is None


def test_reset_status_is_bounded_read_only_and_retries_current_state(monkeypatch):
    from types import SimpleNamespace

    from jrbar import provider_reset_settings_action as actions
    from jrbar.core_runtime import _cmd_reset_status
    from jrbar.provider_reset_events import ResetDeliveryEvent, ResetDeliverySettings, ResetDeliveryState

    events = tuple(ResetDeliveryEvent(str(i), 'fixture', 'default', 'weekly', 1, 100,
                                      ResetDeliverySettings()) for i in range(20))
    book = ResetPersistence()
    state = ResetDeliveryState(events=events)
    book.changed(state)
    revisions = []
    def persist(*, retry=False):
        book.changed(state, retry=retry)
        revisions.append(book.revision)
    target = SimpleNamespace(_jrbar_reset_delivery_state=state, _reset_persistence=lambda: book,
                             _persist_reset_delivery_state=persist)
    original = actions.reset_replay_documents
    monkeypatch.setattr(actions, 'reset_replay_documents', lambda controller: original(controller, now=101))
    first = _cmd_reset_status(target, {})
    assert first == _cmd_reset_status(target, {})
    assert len(first['events']) == 16 and first['remaining'] == 4
    assert first['events'][0]['at'] == 100 and first['events'][0]['event_id'] == '0'
    assert not revisions and target._jrbar_reset_delivery_state == state
    retried = _cmd_reset_status(target, {'retry': True})
    assert revisions == [2] and retried['persistence']['dirty']
