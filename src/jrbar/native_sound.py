"""Play the existing reset sound through AudioToolbox, without AppKit."""
import ctypes as c
import os
from functools import lru_cache

from .native_apple_http import _call, _class, _string


@lru_cache(maxsize=1)
def _sound():
    library = c.CDLL("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
    library.AudioServicesCreateSystemSoundID.argtypes = [c.c_void_p, c.POINTER(c.c_uint32)]
    library.AudioServicesCreateSystemSoundID.restype = c.c_int32
    library.AudioServicesPlaySystemSound.argtypes = [c.c_uint32]
    library.AudioServicesPlaySystemSound.restype = None
    text = _string("file:///System/Library/Sounds/Glass.aiff")
    url = _call(_class("NSURL"), "URLWithString:", arguments=(c.c_void_p,), values=(text.pointer,), object_result=True)
    sound = c.c_uint32()
    if library.AudioServicesCreateSystemSoundID(url.pointer, c.byref(sound)):
        raise OSError("reset sound unavailable")
    return library, sound.value


def play_reset_sound():
    if os.environ.get("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ:
        raise RuntimeError("tests cannot play sounds")
    library, sound = _sound()
    library.AudioServicesPlaySystemSound(sound)
    return True
