"""Bounded NSURLSession requests through the Objective-C runtime's C ABI.

Keep Apple's TLS stack and same-origin redirects without importing PyObjC.
Only the completion and redirect callbacks cross into Python.
"""
from __future__ import annotations

import ctypes as c
import itertools
import threading
from functools import lru_cache

from .native_process_info import _Object, _runtime


@lru_cache(maxsize=48)
def _function(result, arguments):
    return c.CFUNCTYPE(result, c.c_void_p, c.c_void_p, *arguments)(("objc_msgSend", _runtime()))


def _call(receiver, selector, result=c.c_void_p, arguments=(), values=(), *, object_result=False):
    runtime = _runtime()
    pool = runtime.objc_autoreleasePoolPush()
    try:
        value = _function(result, arguments)(receiver, runtime.sel_registerName(selector.encode()), *values)
        if object_result and value:
            return _Object(runtime.objc_retain(value))
        return value
    finally:
        runtime.objc_autoreleasePoolPop(pool)


def _class(name):
    value = _runtime().objc_getClass(name.encode())
    if not value:
        raise RuntimeError("native HTTP class unavailable")
    return value


def _string(text):
    return _call(_class("NSString"), "stringWithUTF8String:", arguments=(c.c_char_p,),
                 values=(text.encode(),), object_result=True)


def _text(pointer):
    return (_call(pointer, "UTF8String", c.c_char_p) or b"").decode("utf-8")


def _origin(url):
    scheme = _call(url, "scheme", object_result=True)
    host = _call(url, "host", object_result=True)
    port = _call(url, "port", object_result=True)
    return (_text(scheme.pointer) if scheme else "", _text(host.pointer) if host else "",
            int(_call(port.pointer, "integerValue", c.c_long)) if port else None)


class _BlockDescriptor(c.Structure):
    _fields_ = [("reserved", c.c_ulong), ("size", c.c_ulong), ("signature", c.c_char_p)]


class _Block(c.Structure):
    _fields_ = [("isa", c.c_void_p), ("flags", c.c_int), ("reserved", c.c_int),
                ("invoke", c.c_void_p), ("descriptor", c.POINTER(_BlockDescriptor)), ("token", c.c_uint64)]


_callbacks = {}
_origins = {}
_tokens = itertools.count(1)
_delegate_lock = threading.Lock()


@c.CFUNCTYPE(None, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p)
def _complete(block, data, response, error):
    token = c.cast(block, c.POINTER(_Block)).contents.token
    callback = _callbacks.pop(token, None)
    if callback is not None:
        callback(data, response, error)


@c.CFUNCTYPE(None, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p)
def _redirect(receiver, _selector, _session, _task, _response, request, handler):
    allowed = False
    try:
        url = _call(request, "URL", object_result=True)
        allowed = url is not None and _origin(url.pointer) == _origins.get(receiver)
    except Exception:
        pass
    block = c.cast(handler, c.POINTER(_Block)).contents
    invoke = c.CFUNCTYPE(None, c.c_void_p, c.c_void_p)(block.invoke)
    invoke(handler, request if allowed else None)


@lru_cache(maxsize=1)
def _delegate_class():
    with _delegate_lock:
        runtime = _runtime()
        runtime.objc_allocateClassPair.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t]
        runtime.objc_allocateClassPair.restype = c.c_void_p
        runtime.class_addMethod.argtypes = [c.c_void_p, c.c_void_p, c.c_void_p, c.c_char_p]
        runtime.class_addMethod.restype = c.c_bool
        runtime.objc_registerClassPair.argtypes = [c.c_void_p]
        name = b"JRBarSameOriginHTTPDelegate"
        existing = runtime.objc_getClass(name)
        if existing:
            return existing
        cls = runtime.objc_allocateClassPair(_class("NSObject"), name, 0)
        selector = runtime.sel_registerName(b"URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:")
        if not cls or not runtime.class_addMethod(cls, selector, c.cast(_redirect, c.c_void_p), b"v@:@@@@@?"):
            raise RuntimeError("native redirect delegate unavailable")
        runtime.objc_registerClassPair(cls)
        return cls


_descriptor = _BlockDescriptor(0, c.sizeof(_Block), b"v@?@@@")


def request(url, *, method, headers, body=None, timeout):
    pointer = c.c_void_p
    text = _string(url)
    native_url = _call(_class("NSURL"), "URLWithString:", arguments=(pointer,), values=(text.pointer,), object_result=True)
    if native_url is None:
        raise ValueError("invalid URL")
    request = _call(_class("NSMutableURLRequest"), "requestWithURL:", arguments=(pointer,), values=(native_url.pointer,), object_result=True)
    verb = _string(method)
    _call(request.pointer, "setHTTPMethod:", None, (pointer,), (verb.pointer,))
    _call(request.pointer, "setTimeoutInterval:", None, (c.c_double,), (float(timeout),))
    for key, value in headers.items():
        name, content = _string(key), _string(value)
        _call(request.pointer, "setValue:forHTTPHeaderField:", None, (pointer, pointer), (content.pointer, name.pointer))
    if body is not None:
        data = _call(_class("NSData"), "dataWithBytes:length:", arguments=(c.c_char_p, c.c_ulong),
                     values=(body, len(body)), object_result=True)
        _call(request.pointer, "setHTTPBody:", None, (pointer,), (data.pointer,))
    delegate = _Object(_call(_delegate_class(), "new"))
    _origins[delegate.pointer] = _origin(native_url.pointer)
    configuration = _call(_class("NSURLSessionConfiguration"), "ephemeralSessionConfiguration", object_result=True)
    session = _call(_class("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:",
                    arguments=(pointer, pointer, pointer), values=(configuration.pointer, delegate.pointer, None), object_result=True)
    done = threading.Event()
    outcome = {}

    def completed(data, response, error):
        try:
            if error or not response:
                outcome["error"] = True
                return
            size = int(_call(data, "length", c.c_ulong)) if data else 0
            if size > 2 * 1024 * 1024:
                outcome["error"] = True
                return
            outcome["status"] = int(_call(response, "statusCode", c.c_long))
            outcome["body"] = c.string_at(_call(data, "bytes"), size) if size else b""
        except Exception:
            outcome["error"] = True
        finally:
            done.set()

    token = next(_tokens)
    _callbacks[token] = completed
    system = c.CDLL("/usr/lib/libSystem.B.dylib")
    isa = c.addressof(c.c_void_p.in_dll(system, "_NSConcreteStackBlock"))
    block = _Block(isa, 1 << 30, 0, c.cast(_complete, pointer), c.pointer(_descriptor), token)
    task = None
    try:
        task = _call(session.pointer, "dataTaskWithRequest:completionHandler:", arguments=(pointer, pointer),
                     values=(request.pointer, c.byref(block)), object_result=True)
        _call(task.pointer, "resume", None)
        if not done.wait(max(1.0, float(timeout)) + 1.0) or outcome.get("error") or not outcome.get("status"):
            raise OSError("native HTTP request unavailable")
        return outcome["status"], outcome.get("body", b"")
    finally:
        _callbacks.pop(token, None)
        _origins.pop(delegate.pointer, None)
        if task is not None:
            _call(task.pointer, "cancel", None)
        _call(session.pointer, "invalidateAndCancel", None)
