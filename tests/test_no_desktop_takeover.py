"""The daemon never takes the desktop, and neither does the suite.

JR-Bar's Python process is an accessory with no windows: the Swift app owns
every one of them.  Reported live 2026-08-26, the suite once made the machine
unusable because product paths called makeKeyAndOrderFront_ and
activateIgnoringOtherApps_ while AppKit tests ran.  conftest now sets the
PROHIBITED activation policy, and this source ratchet fails the build if
any module in the package asks for the front again.
"""

from __future__ import annotations

import re
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src" / "jrbar"

_TAKEOVER_CALLS = re.compile(
    r"activateIgnoringOtherApps_|orderFrontRegardless|makeKeyAndOrderFront_"
)


def test_no_module_asks_to_be_put_in_front_of_the_person() -> None:
    offenders: list[str] = []
    for path in sorted(SRC.glob("*.py")):
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
            if _TAKEOVER_CALLS.search(line) and not line.lstrip().startswith("#"):
                offenders.append(f"{path.name}:{line_number}: {line.strip()}")
    assert not offenders, (
        "the daemon has no windows to order front; the Swift app owns them: "
        f"{offenders}"
    )
