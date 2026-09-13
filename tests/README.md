# Test suite layout and reduction notes

The suite was reduced from ~10,400 collected tests to ~3,300 by
consolidating redundant structure while keeping one meaningful test per
real behavior. No application code was changed.

## What was consolidated and why

- **Parametrized tests** — `@pytest.mark.parametrize` case lists were
  folded into explicit `for` loops inside a single test. Every input
  case still runs; only the collection granularity changed.
- **Adjacent same-signature tests** — runs of module-level test
  functions sharing the same fixture signature were merged into grouped
  tests of three, with each original body preserved as a labelled
  `# --- scenario:` block. Fixture state is reset between scenarios
  (`monkeypatch.undo()`, `mocker.stopall()`, `caplog.clear()`,
  `capsys/capfd.readouterr()`). Groups whose scenarios share live
  objects, module singletons, or global state that cannot be reset
  generically were left unmerged.
- **Legacy monolith (`test_jrbar.py`)** — heavily duplicated
  `unittest.TestCase` methods (provider registry sweeps, repeated
  rendering/geometry variants, per-constant assertions) were folded into
  scenario-loop tests; distinct behaviors were kept.

## What was deliberately kept

Unique coverage was not deleted: daemon protocol codec edges, provider
adapter parsing and usage truthfulness, session/naming hygiene, device
and screen-bar state machines, state projection/lifecycle semantics,
history consent/retention, packaging/release/LaunchAgent contracts,
security and private-state handling, and shipped regressions.

## Conventions for merged tests

- Merged tests are named `test_<first>__and_<N>_more`.
- Each scenario block is labelled with the original test name minus the
  `test_` prefix, so failures still identify the original case.
- When adding tests near merged groups, prefer a separate `def` (or add
  a scenario block) rather than re-splitting the group.
