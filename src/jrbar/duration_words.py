"""How long something lasts, in the words the app uses.

The app's ``UsageTime.duration`` (app/Sources/JRBarCore/Wording.swift) and
this function read the same table, so a countdown the daemon words and one
the app words never disagree: "45s", "12m 30s", "1h", "1h 05m", "3d",
"3d 4h". A whole hour or a whole day drops its zeros -- "1h", never
"1h 00m" -- and a partial hour keeps its padded minutes.
"""

from __future__ import annotations

import math


def duration(seconds: float) -> str:
    """``seconds`` as the app says it; "unknown" for a non-finite value."""
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return "unknown"
    if not math.isfinite(float(seconds)):
        return "unknown"
    whole = max(0, int(seconds))
    if whole < 60:
        return f"{whole}s"
    minutes, rest = divmod(whole, 60)
    if minutes < 60:
        return f"{minutes}m" if rest == 0 else f"{minutes}m {rest}s"
    hours, rest_minutes = divmod(minutes, 60)
    if hours < 24:
        return f"{hours}h" if rest_minutes == 0 else f"{hours}h {rest_minutes:02d}m"
    days, rest_hours = divmod(hours, 24)
    return f"{days}d" if rest_hours == 0 else f"{days}d {rest_hours}h"


__all__ = ["duration"]
