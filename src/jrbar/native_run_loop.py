"""A CoreFoundation run loop for hidapi's process-owned IOHIDManager."""
import ctypes as c


@c.CFUNCTYPE(None, c.c_void_p, c.c_void_p)
def _keepalive(_timer, _context):
    pass


class Pump:
    def __init__(self):
        lib = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.lib = lib
        lib.CFRunLoopGetCurrent.restype = c.c_void_p
        lib.CFAbsoluteTimeGetCurrent.restype = c.c_double
        lib.CFRunLoopTimerCreate.argtypes = [c.c_void_p, c.c_double, c.c_double, c.c_ulong, c.c_long, c.c_void_p, c.c_void_p]
        lib.CFRunLoopTimerCreate.restype = c.c_void_p
        lib.CFRunLoopAddTimer.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p]
        lib.CFRunLoopRunInMode.argtypes = [c.c_void_p, c.c_double, c.c_bool]
        lib.CFRunLoopRunInMode.restype = c.c_int
        lib.CFRunLoopTimerInvalidate.argtypes = [c.c_void_p]
        lib.CFRelease.argtypes = [c.c_void_p]
        self.mode = c.c_void_p.in_dll(lib, "kCFRunLoopDefaultMode").value
        self.loop = lib.CFRunLoopGetCurrent()
        self.timer = lib.CFRunLoopTimerCreate(None, lib.CFAbsoluteTimeGetCurrent() + 3600, 3600, 0, 0, _keepalive, None)
        if not self.timer:
            raise OSError("CoreFoundation keepalive unavailable")
        lib.CFRunLoopAddTimer(self.loop, self.timer, self.mode)

    def run(self, seconds):
        self.lib.CFRunLoopRunInMode(self.mode, float(seconds), False)

    def close(self):
        if self.timer:
            self.lib.CFRunLoopTimerInvalidate(self.timer)
            self.lib.CFRelease(self.timer)
            self.timer = None
