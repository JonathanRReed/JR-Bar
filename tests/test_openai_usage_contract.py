from urllib.parse import parse_qs, urlparse

import pytest

from jrbar.provider_usage_collectors import collect_openai_api
from jrbar.provider_usage_parsers import parse_openai_api_usage
from jrbar.provider_usage_settings import default_provider_usage_settings


def _usage(*rows, **page):
    return {"data": [{"results": list(rows)}], **page}


def _tokens(total=100, cached=40, model="model-fixture"):
    return {"input_tokens": total, "input_cached_tokens": cached,
            "output_tokens": 25, "model": model}


def _cost(value=1.25, currency="usd", **page):
    return _usage({"amount": {"value": value, "currency": currency}}, **page)


class _Credentials:
    def get(self, provider, account):
        assert (provider, account) == ("openai-api", "admin-key")
        return type("Read", (), {"available": True, "secret": "fixture-admin"})()


def _collect(pages):
    calls = []
    responses = iter(pages)

    def http(method, url, *, headers, timeout):
        assert method == "GET"
        assert urlparse(url).netloc == "api.openai.com"
        assert headers == {"Authorization": "Bearer fixture-admin"}
        calls.append(parse_qs(urlparse(url).query))
        return next(responses)

    snapshot = collect_openai_api(
        default_provider_usage_settings().preference("openai-api"),
        observed_at=3_000_000,
        credentials=_Credentials(),
        http_json=http,
    )
    return snapshot, calls


def test_cached_input_remains_part_of_the_total_once():
    snapshot = parse_openai_api_usage(
        {"usage": _usage(_tokens()), "costs": _cost()}, observed_at=1000
    )
    assert snapshot.input_tokens == 60
    assert snapshot.cached_input_tokens == 40
    assert snapshot.input_tokens + snapshot.cached_input_tokens + snapshot.output_tokens == 125
    assert snapshot.estimated_cost_usd == 1.25


def test_model_grouping_and_all_usage_and_cost_pages_are_collected():
    snapshot, calls = _collect([
        _usage(_tokens(), has_more=True, next_page="usage+cursor/one"),
        _usage(_tokens(50, 10, "second-fixture"), has_more=False),
        _cost(has_more=True, next_page="costs+cursor/two"),
        _cost(2.0, has_more=False),
    ])
    assert snapshot.state.value == "ready"
    assert snapshot.model_count == 2
    assert snapshot.input_tokens == 100
    assert snapshot.cached_input_tokens == 50
    assert snapshot.output_tokens == 50
    assert snapshot.estimated_cost_usd == 3.25
    assert calls[0]["group_by"] == ["model"]
    assert calls[1]["group_by"] == ["model"]
    assert calls[1]["page"] == ["usage+cursor/one"]
    assert calls[3]["page"] == ["costs+cursor/two"]
    assert "group_by" not in calls[2]
    assert all(call["start_time"] == calls[0]["start_time"] for call in calls)


@pytest.mark.parametrize("usage", [
    {}, {"error": {"message": "fixture error"}}, {"data": None},
    {"data": [{}]}, {"data": [{"results": [None]}]},
    _usage(_tokens(), has_more=True), _usage(_tokens(cached=101)),
    _usage(_tokens(total=True)), _usage(_tokens(cached=float("nan"))),
    _usage({"model": "fixture"}),
])
def test_malformed_or_incomplete_usage_cannot_become_a_ready_zero(usage):
    with pytest.raises(ValueError):
        parse_openai_api_usage({"usage": usage, "costs": _cost()}, observed_at=1000)


def test_a_currency_other_than_usd_cannot_be_labeled_usd():
    with pytest.raises(ValueError):
        parse_openai_api_usage(
            {"usage": _usage(_tokens()), "costs": _cost(currency="eur")},
            observed_at=1000,
        )


def test_reported_zero_usage_is_still_a_valid_reading():
    snapshot = parse_openai_api_usage(
        {"usage": _usage({**_tokens(0, 0), "output_tokens": 0}), "costs": _cost(0)}, observed_at=1000
    )
    assert snapshot.state.value == "ready"
    assert snapshot.input_tokens == snapshot.cached_input_tokens == snapshot.output_tokens == 0
    assert snapshot.estimated_cost_usd == 0


@pytest.mark.parametrize("pages, count", [
    ([{}], 1),
    ([_usage(has_more=True)], 1),
    ([_usage(has_more="true", next_page="cursor")], 1),
    ([_usage(has_more=True, next_page="same")] * 2, 2),
    ([_usage(has_more=True, next_page=str(i)) for i in range(4)], 4),
])
def test_bad_or_unbounded_pagination_returns_an_error(pages, count):
    snapshot, calls = _collect(pages)
    assert snapshot.state.value == "error"
    assert snapshot.reason_code == "invalid_provider_response"
    assert len(calls) == count


def test_a_later_malformed_page_does_not_publish_partial_totals():
    snapshot, calls = _collect([
        _usage(_tokens(), has_more=True, next_page="cursor"),
        {"data": [{"results": "invalid"}], "has_more": False},
        _cost(),
    ])
    assert snapshot.state.value == "error"
    assert snapshot.input_tokens == 0
    assert len(calls) == 3
