#!/usr/bin/env python3
"""Build the provider marks the app draws, from the pinned upstream SVGs.

Reads the sources under ``app/Resources/ProviderLogos/`` (each one's origin,
revision and licence is in ``MARKS`` below and in that folder's
``NOTICE.txt``) and writes ``app/Sources/JRBarUI/ProviderLogoData.swift``:
one non-zero path per mark in a 1000-unit square, y-down, centred, with
the mark's optical scale applied. The boolean work (fill rules, strokes,
knock-outs) happens here, once, with CoreGraphics through PyObjC, so the
app only ever parses a finished path string.

Every write checks its own output at 128 px: the shipped string must fill
the same pixels as the normalised path, and the normalised path the same
pixels as the source drawn its own way (fill rules, strokes and knock-outs
in order). Nothing is written while a mark fails either check.

    .venv/bin/python scripts/gen_provider_logos.py           regenerate
    .venv/bin/python scripts/gen_provider_logos.py --check   is the file current?

``--check`` needs no CoreGraphics: it hashes the recipes (the table plus
the path data read from the sources) and the shipped strings, and compares
them with the two digests the generated file carries. ``make fast`` runs it
through ``tests/test_provider_logo_data.py``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "app" / "Resources" / "ProviderLogos"
OUTPUT = ROOT / "app" / "Sources" / "JRBarUI" / "ProviderLogoData.swift"
# Bump when the output format or the path pipeline changes, so an old file
# fails the check even when no source moved.
FORMAT_VERSION = 1
UNITS = 1000


# MARK: - Sources


@dataclass(frozen=True)
class Source:
    name: str
    url: str
    revision: str
    licence: str


SIMPLE_ICONS = Source(
    "Simple Icons",
    "https://github.com/simple-icons/simple-icons",
    "16.32.0 @ 3173436c1255ab7cdc9c38ab85ca0fca333688d9",
    "CC0-1.0 (the SVG data; each mark stays its owner's trademark)",
)
LOBEHUB = Source(
    "LobeHub Icons (@lobehub/icons-static-svg)",
    "https://github.com/lobehub/lobe-icons",
    "1.95.1 @ 49a2130df7bfa5eb1b088261bff20a37e2967789",
    "MIT, Copyright (c) 2023 LobeHub",
)
OPENCLAW = Source(
    "OpenClaw",
    "https://github.com/openclaw/openclaw",
    "956cca8af6751929df2174b119f2340efaa2418c",
    "MIT, Copyright (c) 2026 OpenClaw Foundation",
)
T3CODE = Source(
    "T3 Code",
    "https://github.com/pingdotgg/t3code",
    "99641fd09a509feb644b3c8ef718c12c60cf436c",
    "MIT, Copyright (c) 2026 T3 Tools Inc.",
)
JRBAR = Source(
    "JR-Bar",
    "app/Sources/JRBarUI/StatusIconRenderer.swift (drawMark)",
    "07c7232f",
    "JR-Bar's own mark",
)


# MARK: - Layers


@dataclass(frozen=True)
class Layer:
    """One step of a mark: fill a path (with its rule), knock one out, or
    stroke one with round caps and joins."""

    d: str
    op: str = "fill"  # fill | subtract | stroke
    even_odd: bool = False
    width: float = 0.0

    def recipe(self) -> dict[str, object]:
        return {"d": self.d, "op": self.op, "even_odd": self.even_odd, "width": self.width}


_VIEWBOX = re.compile(r'viewBox="([^"]+)"')
_PATH = re.compile(r"<path([^>]*)>")
_D = re.compile(r'\sd="([^"]+)"')
_SVG_OPEN = re.compile(r"<svg[^>]*>")


def svg_layers(relative: str) -> list[Layer]:
    """The ``<path>`` fills of a plain single-colour SVG, in order, each
    with the fill rule the file gives it (on the path or on the root)."""
    text = (SOURCES / relative).read_text(encoding="utf-8")
    root = _SVG_OPEN.search(text)
    root_even_odd = bool(root and 'fill-rule="evenodd"' in root.group(0))
    layers = []
    for attributes in _PATH.findall(text):
        found = _D.search(attributes)
        if not found:
            continue
        even_odd = root_even_odd or 'fill-rule="evenodd"' in attributes
        layers.append(Layer(" ".join(found.group(1).split()), even_odd=even_odd))
    if not layers:
        raise ValueError(f"{relative}: no path data")
    return layers


def _number(value: float) -> str:
    return f"{value:g}"


def circle(cx: float, cy: float, r: float) -> str:
    return ellipse(cx, cy, r, r)


def ellipse(cx: float, cy: float, rx: float, ry: float) -> str:
    left, right = _number(cx - rx), _number(cx + rx)
    return (
        f"M{left} {_number(cy)}A{_number(rx)} {_number(ry)} 0 1 0 {right} {_number(cy)}"
        f"A{_number(rx)} {_number(ry)} 0 1 0 {left} {_number(cy)}Z"
    )


def rounded_rect(x: float, y: float, w: float, h: float, r: float) -> str:
    n = _number
    return (
        f"M{n(x + r)} {n(y)}H{n(x + w - r)}A{n(r)} {n(r)} 0 0 1 {n(x + w)} {n(y + r)}V{n(y + h - r)}"
        f"A{n(r)} {n(r)} 0 0 1 {n(x + w - r)} {n(y + h)}H{n(x + r)}A{n(r)} {n(r)} 0 0 1 {n(x)} {n(y + h - r)}"
        f"V{n(y + r)}A{n(r)} {n(r)} 0 0 1 {n(x + r)} {n(y)}Z"
    )


def openclaw_critter() -> list[Layer]:
    """``openclaw/tray-template.svg``, OpenClaw's own 18 pt menu-bar
    template: its mask written out as layers (antennae, legs, arm nubs and
    body filled; the eyes knocked out; the glints put back)."""
    return [
        Layer("M6.926 4.563 Q6.149 1.35 3.816 1.62 M11.074 4.563 Q11.851 1.35 14.184 1.62", "stroke", width=2.07),
        Layer(rounded_rect(5.4, 12.96, 2.52, 3.24, 1.26)),
        Layer(rounded_rect(10.08, 12.96, 2.52, 3.24, 1.26)),
        Layer(circle(2.7, 9.59, 1.8)),
        Layer(circle(15.3, 9.59, 1.8)),
        Layer(ellipse(9, 8.64, 6.48, 5.94)),
        Layer(ellipse(6.149, 7.69, 1.426, 1.544), "subtract"),
        Layer(ellipse(11.851, 7.69, 1.426, 1.544), "subtract"),
        Layer(circle(5.522, 7.134, 0.741)),
        Layer(circle(11.224, 7.134, 0.741)),
    ]


def openclaw_molty() -> list[Layer]:
    """``openclaw/molty.svg``, the full mascot, as one ink: body, claws and
    antennae filled, the eyes knocked out, the pupils put back
    (``translate(0 2)`` is folded into the fitting, which ignores offsets)."""
    return [
        Layer(
            "M60 10 C30 10 15 35 15 55 C15 75 30 95 45 100 L45 110 L55 110 L55 100 C55 100 60 102 65 100 "
            "L65 110 L75 110 L75 100 C90 95 105 75 105 55 C105 35 90 10 60 10Z"
        ),
        Layer("M20 45 C5 40 0 50 5 60 C10 70 20 65 25 55 C28 48 25 45 20 45Z"),
        Layer("M100 45 C115 40 120 50 115 60 C110 70 100 65 95 55 C92 48 95 45 100 45Z"),
        Layer("M45 15 Q35 5 30 8 M75 15 Q85 5 90 8", "stroke", width=3),
        Layer(circle(45, 35, 6), "subtract"),
        Layer(circle(75, 35, 6), "subtract"),
        Layer(circle(46, 34, 2.5)),
        Layer(circle(76, 34, 2.5)),
    ]


def jrbar_mark() -> list[Layer]:
    """``StatusIconRenderer.drawMark``'s 18 pt geometry flipped to y-down:
    the notch cap over the rounded bar, both in one ink."""
    cap = "M4.5 2.5L13.5 2.5L13.5 5.8C13.5 6.8 12.7 7.6 11.7 7.6L6.3 7.6C5.3 7.6 4.5 6.8 4.5 5.8Z"
    return [Layer(cap), Layer(rounded_rect(2.5, 8.8, 13, 3.6, 1.8))]


# MARK: - The table


@dataclass(frozen=True)
class Mark:
    id: str
    label: str
    source: Source
    files: tuple[str, ...]
    layers: list[Layer] = field(compare=False)
    # How much of the square the mark's longer side fills: solid, blocky
    # marks read heavier than line marks at the same extent, so they sit a
    # little smaller.
    optical: float = 1.0
    note: str = ""

    def recipe(self) -> dict[str, object]:
        return {
            "id": self.id,
            "optical": self.optical,
            "layers": [layer.recipe() for layer in self.layers],
        }


def _svg(mark_id: str, label: str, source: Source, relative: str, optical: float, note: str) -> Mark:
    return Mark(mark_id, label, source, (relative,), svg_layers(relative), optical, note)


def marks() -> list[Mark]:
    """Every mark the app ships, keyed by what it depicts. ``ProviderStyle``
    maps provider ids onto these; the alternatives (the Codex app mark,
    xAI's letter mark, the full Molty, LobeHub's newer Gemini) stay here so
    a default can flip without a new source."""
    return [
        _svg("claude", "Claude", SIMPLE_ICONS, "simple-icons/claude.svg", 1.0, "the Claude spark; slug claude"),
        _svg("openai", "OpenAI", LOBEHUB, "lobehub/openai.svg", 0.96, "the OpenAI blossom; slug openai"),
        _svg("codex", "Codex app", LOBEHUB, "lobehub/codex.svg", 0.96, "the Codex app's cloud with >_; slug codex"),
        _svg("gemini", "Gemini", SIMPLE_ICONS, "simple-icons/googlegemini.svg", 1.0, "slug googlegemini"),
        _svg("gemini.lobe", "Gemini (rounded)", LOBEHUB, "lobehub/gemini.svg", 1.0, "the newer sparkle; slug gemini"),
        _svg("pi", "Pi", SIMPLE_ICONS, "simple-icons/pi.svg", 0.84, "pi.dev's mark; slug pi"),
        _svg("grok", "Grok", LOBEHUB, "lobehub/grok.svg", 0.98, "slug grok"),
        _svg("xai", "xAI", LOBEHUB, "lobehub/xai.svg", 0.9, "xAI's letter mark; slug xai"),
        _svg("devin", "Devin", LOBEHUB, "lobehub/devin.svg", 0.98, "slug devin"),
        _svg("opencode", "OpenCode", SIMPLE_ICONS, "simple-icons/opencode.svg", 0.84, "slug opencode"),
        Mark(
            "openclaw",
            "OpenClaw",
            OPENCLAW,
            ("openclaw/tray-template.svg",),
            openclaw_critter(),
            1.0,
            "apps/linux/src-tauri/icons/tray-template.svg, the 18 pt template critter",
        ),
        Mark(
            "openclaw.molty",
            "OpenClaw (Molty)",
            OPENCLAW,
            ("openclaw/molty.svg",),
            openclaw_molty(),
            1.0,
            "apps/macos/Icon.icon/Assets/molty.svg",
        ),
        _svg("antigravity", "Antigravity", LOBEHUB, "lobehub/antigravity.svg", 1.0, "slug antigravity"),
        _svg("cursor", "Cursor", SIMPLE_ICONS, "simple-icons/cursor.svg", 0.98, "slug cursor"),
        _svg("hermes", "Hermes Agent", LOBEHUB, "lobehub/hermesagent.svg", 1.0, "slug hermesagent"),
        _svg("kiro", "Kiro", LOBEHUB, "lobehub/kiro.svg", 0.98, "slug kiro"),
        _svg("t3code", "T3 Code", T3CODE, "t3code/T3Mark.svg", 1.0, "apps/mobile/assets/widget/T3Mark.svg"),
        Mark("jrbar", "JR-Bar", JRBAR, (), jrbar_mark(), 1.0, "the notch cap over the bar"),
    ]


# MARK: - SVG path data (pure Python)

Segment = tuple  # ("M", x, y) | ("L", x, y) | ("Q", cx, cy, x, y) | ("C", ...6) | ("Z",)

_COMMANDS = frozenset(b"MmLlHhVvCcSsQqTtAaZz")


class PathError(ValueError):
    pass


class _Scanner:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.index = 0

    def peek(self) -> int | None:
        return self.data[self.index] if self.index < len(self.data) else None

    def skip(self) -> None:
        while self.index < len(self.data) and self.data[self.index] in b" ,\t\n\r":
            self.index += 1

    def number(self) -> float:
        self.skip()
        begin = self.index
        data = self.data
        if self.peek() in (43, 45):  # + -
            self.index += 1
        digits = 0
        while self.index < len(data) and 48 <= data[self.index] <= 57:
            self.index += 1
            digits += 1
        if self.peek() == 46:  # .
            self.index += 1
            while self.index < len(data) and 48 <= data[self.index] <= 57:
                self.index += 1
                digits += 1
        if digits == 0:
            raise PathError(f"expected a number at {begin}")
        if self.peek() in (101, 69):  # e E
            save = self.index
            self.index += 1
            if self.peek() in (43, 45):
                self.index += 1
            exponent = 0
            while self.index < len(data) and 48 <= data[self.index] <= 57:
                self.index += 1
                exponent += 1
            if exponent == 0:
                self.index = save
        return float(data[begin : self.index].decode("ascii"))

    def point(self, base: tuple[float, float]) -> tuple[float, float]:
        x = self.number()
        y = self.number()
        return (x + base[0], y + base[1])

    def flag(self) -> bool:
        self.skip()
        value = self.peek()
        if value not in (48, 49):
            raise PathError(f"arc flag at {self.index}")
        self.index += 1
        return value == 49


def _arc(segments: list[Segment], p0, rx: float, ry: float, degrees: float, large: bool, sweep: bool, p1) -> None:
    """SVG's endpoint arc as cubic Béziers (SVG 1.1 F.6.5–F.6.6), one per
    quarter turn at most. The app's Swift parser does the same sums."""
    if p0 == p1:
        return
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        segments.append(("L", p1[0], p1[1]))
        return
    phi = degrees * math.pi / 180
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx2, dy2 = (p0[0] - p1[0]) / 2, (p0[1] - p1[1]) / 2
    x1 = cos_phi * dx2 + sin_phi * dy2
    y1 = -sin_phi * dx2 + cos_phi * dy2
    lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    coef = (1 if large != sweep else -1) * math.sqrt(max(0.0, num / den))
    cxp = coef * rx * y1 / ry
    cyp = -coef * ry * x1 / rx
    cx = cos_phi * cxp - sin_phi * cyp + (p0[0] + p1[0]) / 2
    cy = sin_phi * cxp + cos_phi * cyp + (p0[1] + p1[1]) / 2

    def angle(ux: float, uy: float, vx: float, vy: float) -> float:
        return math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)

    ux, uy = (x1 - cxp) / rx, (y1 - cyp) / ry
    vx, vy = (-x1 - cxp) / rx, (-y1 - cyp) / ry
    theta = angle(1, 0, ux, uy)
    delta = angle(ux, uy, vx, vy)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi
    count = max(1, math.ceil(abs(delta) / (math.pi / 2)))
    step = delta / count
    t = 4.0 / 3.0 * math.tan(step / 4)

    def place(u: float, v: float) -> tuple[float, float]:
        return (cx + rx * cos_phi * u - ry * sin_phi * v, cy + rx * sin_phi * u + ry * cos_phi * v)

    a = theta
    for index in range(count):
        b = a + step
        ca, sa, cb, sb = math.cos(a), math.sin(a), math.cos(b), math.sin(b)
        c1 = place(ca - t * sa, sa + t * ca)
        c2 = place(cb + t * sb, sb - t * cb)
        end = p1 if index == count - 1 else place(cb, sb)
        segments.append(("C", c1[0], c1[1], c2[0], c2[1], end[0], end[1]))
        a = b


def parse_path(d: str) -> list[Segment]:
    """SVG path data to absolute segments: every command, implicit repeats,
    packed numbers (``.5.5``, ``1-2``), packed arc flags and exponents."""
    scanner = _Scanner(d.encode("ascii"))
    segments: list[Segment] = []
    current = start = (0.0, 0.0)
    last_cubic = last_quad = None
    command = 0
    while True:
        scanner.skip()
        byte = scanner.peek()
        if byte is None:
            break
        if byte in _COMMANDS:
            command = byte
            scanner.index += 1
        elif command == 0:
            raise PathError(f"data before the first command at {scanner.index}")
        relative = command >= 97
        base = current if relative else (0.0, 0.0)
        kind = command | 0x20
        if kind == 109:  # m
            current = start = scanner.point(base)
            segments.append(("M", *current))
            last_cubic = last_quad = None
            command = 108 if relative else 76
        elif kind == 108:  # l
            current = scanner.point(base)
            segments.append(("L", *current))
            last_cubic = last_quad = None
        elif kind == 104:  # h
            current = (scanner.number() + (current[0] if relative else 0), current[1])
            segments.append(("L", *current))
            last_cubic = last_quad = None
        elif kind == 118:  # v
            current = (current[0], scanner.number() + (current[1] if relative else 0))
            segments.append(("L", *current))
            last_cubic = last_quad = None
        elif kind == 99:  # c
            c1, c2, p = scanner.point(base), scanner.point(base), scanner.point(base)
            segments.append(("C", *c1, *c2, *p))
            current, last_cubic, last_quad = p, c2, None
        elif kind == 115:  # s
            c1 = (2 * current[0] - last_cubic[0], 2 * current[1] - last_cubic[1]) if last_cubic else current
            c2, p = scanner.point(base), scanner.point(base)
            segments.append(("C", *c1, *c2, *p))
            current, last_cubic, last_quad = p, c2, None
        elif kind == 113:  # q
            c, p = scanner.point(base), scanner.point(base)
            segments.append(("Q", *c, *p))
            current, last_quad, last_cubic = p, c, None
        elif kind == 116:  # t
            c = (2 * current[0] - last_quad[0], 2 * current[1] - last_quad[1]) if last_quad else current
            p = scanner.point(base)
            segments.append(("Q", *c, *p))
            current, last_quad, last_cubic = p, c, None
        elif kind == 97:  # a
            rx, ry, rotation = scanner.number(), scanner.number(), scanner.number()
            large, sweep = scanner.flag(), scanner.flag()
            p = scanner.point(base)
            _arc(segments, current, rx, ry, rotation, large, sweep, p)
            current, last_cubic, last_quad = p, None, None
        elif kind == 122:  # z
            segments.append(("Z",))
            current, last_cubic, last_quad = start, None, None
            scanner.skip()
            following = scanner.peek()
            if following is not None and following not in _COMMANDS:
                raise PathError(f"number after Z at {scanner.index}")
            command = 0
        else:
            raise PathError(f"unknown command {chr(command)}")
    return segments


def _extrema(p0: float, p1: float, p2: float, p3: float) -> list[float]:
    """Where a cubic's coordinate turns, for t strictly inside 0…1."""
    a = -p0 + 3 * p1 - 3 * p2 + p3
    b = 2 * (p0 - 2 * p1 + p2)
    c = p1 - p0
    if abs(a) < 1e-12:
        roots = [-c / b] if abs(b) > 1e-12 else []
    else:
        disc = b * b - 4 * a * c
        if disc < 0:
            return []
        root = math.sqrt(disc)
        roots = [(-b + root) / (2 * a), (-b - root) / (2 * a)]
    return [t for t in roots if 0 < t < 1]


def _cubic(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
    u = 1 - t
    return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3


def path_bounds(segments: list[Segment]) -> tuple[float, float, float, float]:
    """Min x, min y, max x, max y of the drawn path: end points and the
    curves' turning points, not their control points."""
    xs: list[float] = []
    ys: list[float] = []
    current = start = (0.0, 0.0)
    for segment in segments:
        kind = segment[0]
        if kind == "Z":
            current = start
            continue
        end = (segment[-2], segment[-1])
        if kind == "M":
            start = end
        if kind in ("Q", "C"):
            if kind == "Q":
                q = segment[1:3]
                c1 = (current[0] + 2 / 3 * (q[0] - current[0]), current[1] + 2 / 3 * (q[1] - current[1]))
                c2 = (end[0] + 2 / 3 * (q[0] - end[0]), end[1] + 2 / 3 * (q[1] - end[1]))
            else:
                c1, c2 = segment[1:3], segment[3:5]
            for axis, values in ((0, xs), (1, ys)):
                ends = (current[axis], c1[axis], c2[axis], end[axis])
                values.extend(_cubic(*ends, t) for t in _extrema(*ends))
        xs.append(end[0])
        ys.append(end[1])
        current = end
    if not xs:
        return (0.0, 0.0, 0.0, 0.0)
    return (min(xs), min(ys), max(xs), max(ys))


# MARK: - Output


def _fmt(value: float) -> str:
    """A 1000-unit coordinate at 0.1 resolution (0.0064 px on a 32 pt tile
    at 2x), rounded half away from zero, whole numbers without a point."""
    scaled = math.copysign(math.floor(abs(value * UNITS * 10) + 0.5), value) / 10
    if scaled == math.floor(scaled):
        return str(int(scaled))
    return f"{scaled:.1f}"


def recipes_digest(table: list[Mark]) -> str:
    payload = {"format": FORMAT_VERSION, "units": UNITS, "marks": [mark.recipe() for mark in table]}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def paths_digest(paths: dict[str, str]) -> str:
    joined = "\n".join(f"{key}={paths[key]}" for key in paths)
    return hashlib.sha256(joined.encode()).hexdigest()


def render_swift(table: list[Mark], paths: dict[str, str]) -> str:
    lines = [
        "// GENERATED by scripts/gen_provider_logos.py from app/Resources/ProviderLogos. Do not edit:",
        "// change a source or the script's table, then run",
        "//     .venv/bin/python scripts/gen_provider_logos.py",
        "// One non-zero path per mark in a 1000-unit square, y-down, centred, with the",
        "// optical scale applied. Sources, revisions and licences:",
        "// app/Resources/ProviderLogos/NOTICE.txt. Each mark is its owner's trademark,",
        "// used only to name the provider it stands for.",
        f"// recipes sha256: {recipes_digest(table)}",
        f"// paths sha256: {paths_digest(paths)}",
        "",
        "enum ProviderLogoData {",
        "    static let paths: [String: String] = [",
    ]
    lines += [f'        "{key}": "{value}",' for key, value in paths.items()]
    lines += ["    ]", "}", ""]
    return "\n".join(lines)


_ENTRY = re.compile(r'^        "([^"]+)": "([^"]*)",$', re.MULTILINE)
_DIGEST = re.compile(r"^// (recipes|paths) sha256: ([0-9a-f]{64})$", re.MULTILINE)


def read_generated(text: str) -> tuple[dict[str, str], dict[str, str]]:
    return dict(_ENTRY.findall(text)), dict(_DIGEST.findall(text))


def check(table: list[Mark], text: str) -> list[str]:
    """What is stale or wrong about the generated file; empty when current."""
    problems: list[str] = []
    paths, digests = read_generated(text)
    if digests.get("recipes") != recipes_digest(table):
        problems.append("the sources or the table changed since the file was generated")
    if digests.get("paths") != paths_digest(paths):
        problems.append("the path strings were edited by hand")
    expected = [mark.id for mark in table]
    if list(paths) != expected:
        problems.append(f"marks {list(paths)} != table {expected}")
    for key, value in paths.items():
        try:
            segments = parse_path(value)
        except PathError as error:
            problems.append(f"{key}: {error}")
            continue
        low_x, low_y, high_x, high_y = path_bounds(segments)
        if high_x - low_x <= 0 or high_y - low_y <= 0:
            problems.append(f"{key}: empty")
        if low_x < -0.5 or low_y < -0.5 or high_x > UNITS + 0.5 or high_y > UNITS + 0.5:
            problems.append(f"{key}: outside the {UNITS}-unit square")
    return problems


# MARK: - Generation (CoreGraphics)


def _cgpath(segments: list[Segment]):
    import Quartz

    path = Quartz.CGPathCreateMutable()
    for segment in segments:
        kind = segment[0]
        if kind == "M":
            Quartz.CGPathMoveToPoint(path, None, segment[1], segment[2])
        elif kind == "L":
            Quartz.CGPathAddLineToPoint(path, None, segment[1], segment[2])
        elif kind == "Q":
            Quartz.CGPathAddQuadCurveToPoint(path, None, *segment[1:])
        elif kind == "C":
            Quartz.CGPathAddCurveToPoint(path, None, *segment[1:])
        else:
            Quartz.CGPathCloseSubpath(path)
    return path


def compose(layers: list[Layer]):
    """The layers as one non-zero path, in the source's own space."""
    import Quartz

    result = None
    for layer in layers:
        parsed = _cgpath(parse_path(layer.d))
        if layer.op == "fill":
            piece = Quartz.CGPathCreateCopyByNormalizing(parsed, layer.even_odd)
            result = piece if result is None else Quartz.CGPathCreateCopyByUnioningPath(result, piece, False)
        elif layer.op == "stroke":
            stroked = Quartz.CGPathCreateCopyByStrokingPath(
                parsed, None, layer.width, Quartz.kCGLineCapRound, Quartz.kCGLineJoinRound, 4
            )
            piece = Quartz.CGPathCreateCopyByNormalizing(stroked, False)
            result = piece if result is None else Quartz.CGPathCreateCopyByUnioningPath(result, piece, False)
        elif layer.op == "subtract":
            if result is not None:
                result = Quartz.CGPathCreateCopyBySubtractingPath(result, parsed, layer.even_odd)
        else:
            raise ValueError(f"unknown op {layer.op}")
    return result if result is not None else Quartz.CGPathCreateMutable()


def _fit_transform(path, optical: float):
    import Quartz

    bounds = Quartz.CGPathGetPathBoundingBox(path)
    width, height = bounds.size.width, bounds.size.height
    if width <= 0 or height <= 0:
        raise ValueError("empty mark")
    scale = optical / max(width, height)
    mid_x = bounds.origin.x + width / 2
    mid_y = bounds.origin.y + height / 2
    transform = Quartz.CGAffineTransformMakeTranslation(0.5, 0.5)
    transform = Quartz.CGAffineTransformScale(transform, scale, scale)
    return Quartz.CGAffineTransformTranslate(transform, -mid_x, -mid_y)


def fit(path, optical: float):
    """The path's own bounds (sources pad differently) in the unit square,
    times ``optical``, centred."""
    import Quartz

    return Quartz.CGPathCreateCopyByTransformingPath(path, _fit_transform(path, optical))


def path_string(path) -> str:
    import Quartz

    out: list[str] = []
    counts = {0: 1, 1: 1, 2: 2, 3: 3, 4: 0}
    letters = {0: "M", 1: "L", 2: "Q", 3: "C", 4: "Z"}

    def visit(_info, element) -> None:
        kind = element.type
        points = [element.points[index] for index in range(counts[kind])]
        out.append(letters[kind] + " ".join(f"{_fmt(point.x)} {_fmt(point.y)}" for point in points))

    Quartz.CGPathApply(path, None, visit)
    return "".join(out)


def _coverage(draw, pixels: int) -> bytes:
    import Quartz

    context = Quartz.CGBitmapContextCreate(
        None, pixels, pixels, 8, pixels, Quartz.CGColorSpaceCreateDeviceGray(), Quartz.kCGImageAlphaNone
    )
    Quartz.CGContextSetGrayFillColor(context, 0, 1)
    Quartz.CGContextFillRect(context, ((0, 0), (pixels, pixels)))
    draw(context)
    return bytes(Quartz.CGBitmapContextGetData(context).as_buffer(pixels * pixels))


def _differing(a: bytes, b: bytes, tolerance: int = 32) -> int:
    """Pixels whose coverage differs by more than ``tolerance`` of 255."""
    return sum(1 for x, y in zip(a, b, strict=True) if abs(x - y) > tolerance)


def _fill_path(path, pixels: int, transform) -> bytes:
    import Quartz

    def draw(context) -> None:
        Quartz.CGContextConcatCTM(context, transform)
        Quartz.CGContextSetGrayFillColor(context, 1, 1)
        Quartz.CGContextAddPath(context, path)
        Quartz.CGContextFillPath(context)

    return _coverage(draw, pixels)


def _draw_source(layers: list[Layer], pixels: int, transform) -> bytes:
    """The source drawn the way an SVG renderer would: each fill with its
    own rule, strokes round, knock-outs cleared, in order."""
    import Quartz

    def draw(context) -> None:
        Quartz.CGContextConcatCTM(context, transform)
        for layer in layers:
            path = _cgpath(parse_path(layer.d))
            Quartz.CGContextAddPath(context, path)
            if layer.op == "stroke":
                Quartz.CGContextSetGrayStrokeColor(context, 1, 1)
                Quartz.CGContextSetLineWidth(context, layer.width)
                Quartz.CGContextSetLineCap(context, Quartz.kCGLineCapRound)
                Quartz.CGContextSetLineJoin(context, Quartz.kCGLineJoinRound)
                Quartz.CGContextStrokePath(context)
                continue
            Quartz.CGContextSetGrayFillColor(context, 0 if layer.op == "subtract" else 1, 1)
            if layer.even_odd:
                Quartz.CGContextEOFillPath(context)
            else:
                Quartz.CGContextFillPath(context)

    return _coverage(draw, pixels)


@dataclass
class Built:
    mark: Mark
    d: str
    source_vs_normalised: int
    shipped_vs_normalised: int


def build(mark: Mark, pixels: int = 128) -> Built:
    import Quartz

    raw = compose(mark.layers)
    unit = fit(raw, mark.optical)
    d = path_string(unit)
    # Both checks draw in the unit square scaled to `pixels`.
    scale = Quartz.CGAffineTransformMakeScale(pixels, pixels)
    normalised = _fill_path(unit, pixels, scale)
    source_to_pixels = Quartz.CGAffineTransformConcat(_fit_transform(raw, mark.optical), scale)
    source = _draw_source(mark.layers, pixels, source_to_pixels)
    shipped = _fill_path(_cgpath(parse_path(d)), pixels, Quartz.CGAffineTransformMakeScale(pixels / UNITS, pixels / UNITS))
    # A knock-out drawn over a fill anti-aliases its rim a shade differently
    # from the boolean result (the critter's eyes: two rim pixels 33/255
    # apart), so the source check tolerates a quarter; a wrong fill rule or
    # a lost layer flips whole regions and still fails.
    return Built(mark, d, _differing(source, normalised, tolerance=64), _differing(shipped, normalised))


def generate(table: list[Mark]) -> tuple[str, list[Built]]:
    built = [build(mark) for mark in table]
    paths = {item.mark.id: item.d for item in built}
    return render_swift(table, paths), built


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail when the generated file is stale")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    options = parser.parse_args(arguments)
    table = marks()
    if options.check:
        problems = check(table, options.output.read_text(encoding="utf-8")) if options.output.exists() else [
            f"{options.output} is missing"
        ]
        for problem in problems:
            print(f"provider logos: {problem}", file=sys.stderr)
        if problems:
            print("run: .venv/bin/python scripts/gen_provider_logos.py", file=sys.stderr)
        return 1 if problems else 0
    text, built = generate(table)
    failed = [item for item in built if item.source_vs_normalised or item.shipped_vs_normalised]
    print(f"{'mark':<16}{'bytes':>7}  source/normalised  shipped/normalised (differing px of 128x128)")
    for item in built:
        print(
            f"{item.mark.id:<16}{len(item.d):>7}  {item.source_vs_normalised:>17}  {item.shipped_vs_normalised:>18}"
        )
    if failed:
        print(f"not written: {', '.join(item.mark.id for item in failed)} changed pixels", file=sys.stderr)
        return 1
    options.output.write_text(text, encoding="utf-8")
    print(f"wrote {options.output.relative_to(ROOT) if options.output.is_relative_to(ROOT) else options.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
