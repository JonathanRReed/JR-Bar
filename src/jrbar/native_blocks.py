"""Small copied Objective-C completion blocks for the daemon's native adapters."""
import ctypes as c
import itertools


class Descriptor(c.Structure):
    _fields_ = [("reserved", c.c_ulong), ("size", c.c_ulong), ("signature", c.c_char_p)]


class Block(c.Structure):
    _fields_ = [("isa", c.c_void_p), ("flags", c.c_int), ("reserved", c.c_int),
                ("invoke", c.c_void_p), ("descriptor", c.POINTER(Descriptor)), ("token", c.c_uint64)]


_callbacks = {}
_implementations = {}
_tokens = itertools.count(1)


def completion(callback, argument_types, signature):
    key = (argument_types, signature)
    if key not in _implementations:
        @c.CFUNCTYPE(None, c.c_void_p, *argument_types)
        def invoke(pointer, *arguments):
            token = c.cast(pointer, c.POINTER(Block)).contents.token
            function = _callbacks.pop(token, None)
            if function is not None:
                try:
                    function(*arguments)
                except Exception:
                    pass

        descriptor = Descriptor(0, c.sizeof(Block), signature)
        _implementations[key] = invoke, descriptor
    invoke, descriptor = _implementations[key]
    system = c.CDLL("/usr/lib/libSystem.B.dylib")
    isa = c.addressof(c.c_void_p.in_dll(system, "_NSConcreteStackBlock"))
    token = next(_tokens)
    _callbacks[token] = callback
    return Block(isa, 1 << 30, 0, c.cast(invoke, c.c_void_p), c.pointer(descriptor), token)


def discard(block):
    _callbacks.pop(block.token, None)
