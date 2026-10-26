from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.check_design_tokens import BASELINE, differences, main, offenders, scan


@pytest.mark.parametrize("source,kind", [
    ("Text(\"x\").font(.system(size: 10))", "font"),
    ("Color(\n red: 0.2, green: 0.3, blue: 0.4)", "colour"),
    ("RoundedRectangle(cornerRadius: 9)", "radius"),
    ("view.cornerRadius(9)", "radius"),
    (".easeOut(duration: 0.14)", "animation"),
    (".spring(response: 0.3)", "animation"),
    ('Text("██░░")', "block-meter"),
])
def test_rejects_literal(source, kind):
    assert next(iter(offenders(source))).startswith(kind + ":")


def test_ignores_comments_strings_and_tokens():
    source = '''
    // .system(size: 10)
    /* outer /* Color(red: 1) */ .cornerRadius(8) */
    Text(".easeOut(duration: 0.1)")
    Text(#"Color(red: 1)"#)
    Text(""".system(size: 8)""")
    .font(JRBarTokens.TypeStyle.body.font)
    .clipShape(RoundedRectangle(cornerRadius: JRBarTokens.Radius.group))
    .animation(JRBarTokens.Motion.rowChange.animation, value: selected)
    '''
    assert not offenders(source)


def test_exception_needs_reason_on_the_same_line():
    assert not offenders(".system(size: 13) // jrbar-token-exception: token definition")
    assert offenders(".system(size: 13) // jrbar-token-exception:")
    assert offenders("// jrbar-token-exception: unrelated\n.system(size: 13)")
    assert offenders('Text("// jrbar-token-exception: fake").font(.system(size: 13))')


def test_replacement_cannot_trade_an_old_offender_for_a_new_one():
    assert differences({"a.swift": {"font: .system(size: 9": 1}}, {"a.swift": {"font: .system(size: 10": 1}})
    assert differences({"b.swift": {"radius: cornerRadius: 8": 1}}, {"a.swift": {"radius: cornerRadius: 8": 1}})


def test_prune_only_removes_allowances(tmp_path: Path):
    source = tmp_path / "app/Sources/Test.swift"
    source.parent.mkdir(parents=True)
    source.write_text(".system(size: 12)")
    baseline = tmp_path / BASELINE
    baseline.parent.mkdir()
    baseline.write_text(json.dumps(scan(tmp_path)))
    source.write_text(".system(size: 13)")
    assert main(["--root", str(tmp_path), "--prune"]) == 1
    assert json.loads(baseline.read_text()) == {}


def test_repository_matches_baseline():
    root = Path(__file__).resolve().parents[1]
    assert not differences(scan(root), json.loads((root / BASELINE).read_text()))
