"""Read dyld's current image list without loading a framework."""
from __future__ import annotations

import ctypes as c
import sys


def loaded_images() -> list[str]:
    if sys.platform != "darwin":
        raise OSError("dyld image inventory is unavailable")
    lib = c.CDLL("/usr/lib/libSystem.B.dylib")
    lib._dyld_image_count.restype = c.c_uint32
    lib._dyld_get_image_name.argtypes = [c.c_uint32]
    lib._dyld_get_image_name.restype = c.c_char_p
    return [name.decode() for index in range(lib._dyld_image_count())
            if (name := lib._dyld_get_image_name(index))]


def appkit_loaded() -> bool | None:
    try:
        return any("/appkit.framework/" in name.lower() for name in loaded_images())
    except (OSError, AttributeError, UnicodeError):
        return None
