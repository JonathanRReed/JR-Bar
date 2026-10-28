"""Native JavaScript values must survive collection between Python calls."""

import subprocess
import sys


def test_native_results_survive_collection_before_python_can_protect_them():
    script = r'''
import ctypes
from jrbar.javascript_runtime import JavaScriptContext

context = JavaScriptContext()
library = context.library
# Test-only SPI makes the collection synchronous, without timing or retries.
collect = library.JSSynchronousGarbageCollectForDebugging
collect.argtypes = [ctypes.c_void_p]
collect.restype = None
protect = library.JSValueProtect
protect.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
protect.restype = None
collections = []

def collect_before_protect(ctx, value):
    collect(ctx)
    collections.append(True)
    protect(ctx, value)

library.JSValueProtect = collect_before_protect
string = context._string

def collect_before_string(value):
    collect(context.pointer)
    collections.append(True)
    return string(value)

context._string = collect_before_string
expected = 'a' * 5000 + 'b' * 5000
assert context.evaluateScript_("'a'.repeat(5000) + 'b'.repeat(5000)").toString() == expected
assert context.exception() is None
context.evaluateScript_("function sdledStep() { return 'a'.repeat(5000) + 'b'.repeat(5000); }")
function = context.objectForKeyedSubscript_('sdledStep')
for _ in range(3):
    assert function.callWithArguments_([]).toString() == expected
assert collections
print('collection boundaries verified')
'''
    result = subprocess.run(
        [sys.executable, "-X", "faulthandler", "-c", script],
        capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "collection boundaries verified" in result.stdout


def test_arguments_exceptions_and_retained_functions_survive_native_teardown():
    script = r'''
import ctypes
import gc
import json
from jrbar.javascript_runtime import JavaScriptContext
from jrbar.led_wasm import RawSdLedWasmController

context = JavaScriptContext()
collect = context.library.JSSynchronousGarbageCollectForDebugging
collect.argtypes = [ctypes.c_void_p]
collect.restype = None
for source in ('', 'var sdledStep = 1', 'sdledStep = {}'):
    context.evaluateScript_(source)
    try:
        context.objectForKeyedSubscript_('sdledStep')
    except RuntimeError as error:
        assert 'function unavailable' in str(error)
    else:
        raise AssertionError('non-function accepted')

context.evaluateScript_('function sdledStep() { return JSON.stringify(Array.from(arguments)); }')
function = context.objectForKeyedSubscript_('sdledStep')
arguments = ['embedded\x00text', 'snow \u2603 \U0001f600', '\ud800', True, False, None, 12.5]
assert json.loads(function.callWithArguments_(arguments).toString()) == arguments
assert context.evaluateScript_("'a\\0b'").toString() == 'a\x00b'
assert 'SyntaxError' in context.evaluateScript_('function (').toString()
assert context.exception() is not None
assert context.evaluateScript_('42').toString() == '42'
assert context.exception() is None
context.evaluateScript_('function sdledReset() { throw new Error("synthetic"); }')
try:
    context.objectForKeyedSubscript_('sdledReset').callWithArguments_([])
except RuntimeError as error:
    assert str(error) == 'Error: synthetic'
else:
    raise AssertionError('exception lost')
assert function.callWithArguments_([True]).toString() == '[true]'
assert context.exception() is None
del context
gc.collect()
collect(function.context.pointer)
assert function.callWithArguments_([None]).toString() == '[null]'

for count in (8, 2):
    engine = RawSdLedWasmController(count)
    assert engine.parse('#112233', 0).ok
    collect(engine.context.pointer)
    assert engine.step(0) == [(17, 34, 51)] * count
    engine.cycle = engine
    del engine
    gc.collect()
print('arguments and lifetimes verified')
'''
    result = subprocess.run(
        [sys.executable, "-X", "faulthandler", "-c", script],
        capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "arguments and lifetimes verified" in result.stdout
