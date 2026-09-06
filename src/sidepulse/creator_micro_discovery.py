"""Read-only macOS HID usage-pair discovery for composite Bluetooth devices.

The native HID device can report a keyboard primary usage and still contain
our vendor collection. No device is seized and no report is sent here.
"""
from __future__ import annotations

import ctypes
import sys


def native_vendor_collections() -> frozenset[tuple[int, int, str, int]]:
    if sys.platform != "darwin":
        return frozenset()
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    io = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
    ptr, integer = ctypes.c_void_p, ctypes.c_long

    def function(lib, name, args, result):
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, result
        return fn

    create = function(io, "IOHIDManagerCreate", [ptr, ctypes.c_uint32], ptr)
    matching = function(io, "IOHIDManagerSetDeviceMatching", [ptr, ptr], None)
    open_manager = function(io, "IOHIDManagerOpen", [ptr, ctypes.c_uint32], ctypes.c_int)
    close_manager = function(io, "IOHIDManagerClose", [ptr, ctypes.c_uint32], ctypes.c_int)
    copy_devices = function(io, "IOHIDManagerCopyDevices", [ptr], ptr)
    property_value = function(io, "IOHIDDeviceGetProperty", [ptr, ptr], ptr)
    release = function(cf, "CFRelease", [ptr], None)
    string_create = function(cf, "CFStringCreateWithCString", [ptr, ctypes.c_char_p, ctypes.c_uint32], ptr)
    string_get = function(cf, "CFStringGetCString", [ptr, ptr, integer, ctypes.c_uint32], ctypes.c_bool)
    get_type = function(cf, "CFGetTypeID", [ptr], ctypes.c_ulong)
    type_string = function(cf, "CFStringGetTypeID", [], ctypes.c_ulong)()
    type_number = function(cf, "CFNumberGetTypeID", [], ctypes.c_ulong)()
    type_array = function(cf, "CFArrayGetTypeID", [], ctypes.c_ulong)()
    type_dictionary = function(cf, "CFDictionaryGetTypeID", [], ctypes.c_ulong)()
    number_get = function(cf, "CFNumberGetValue", [ptr, ctypes.c_int, ptr], ctypes.c_bool)
    set_count = function(cf, "CFSetGetCount", [ptr], integer)
    set_values = function(cf, "CFSetGetValues", [ptr, ptr], None)
    array_count = function(cf, "CFArrayGetCount", [ptr], integer)
    array_value = function(cf, "CFArrayGetValueAtIndex", [ptr, integer], ptr)
    dictionary_value = function(cf, "CFDictionaryGetValue", [ptr, ptr], ptr)
    dictionary_create = function(cf, "CFDictionaryCreate", [ptr, ptr, ptr, integer, ptr, ptr], ptr)
    number_create = function(cf, "CFNumberCreate", [ptr, ctypes.c_int, ptr], ptr)
    run_loop = function(cf, "CFRunLoopGetCurrent", [], ptr)
    run_mode = ctypes.c_void_p.in_dll(cf, "kCFRunLoopDefaultMode").value
    run_for = function(cf, "CFRunLoopRunInMode", [ptr, ctypes.c_double, ctypes.c_bool], ctypes.c_int)
    schedule = function(io, "IOHIDManagerScheduleWithRunLoop", [ptr, ptr, ptr], None)
    unschedule = function(io, "IOHIDManagerUnscheduleFromRunLoop", [ptr, ptr, ptr], None)
    keys = {}
    manager = devices = match_dict = vendor_number = loop = None
    opened = scheduled = False

    def key(name):
        if name not in keys:
            keys[name] = string_create(None, name.encode("ascii"), 0x08000100)
        return keys[name]

    def number(value):
        if not value or get_type(value) != type_number:
            return None
        output = ctypes.c_int64()
        return output.value if number_get(value, 4, ctypes.byref(output)) else None

    def text(value):
        if not value or get_type(value) != type_string:
            return ""
        output = ctypes.create_string_buffer(1024)
        return output.value.decode("utf-8") if string_get(value, output, len(output), 0x08000100) else ""

    found = set()
    try:
        manager = create(None, 0)
        if not manager:
            return frozenset()
        vendor_value = ctypes.c_int64(0x303A)
        vendor_number = number_create(None, 4, ctypes.byref(vendor_value))
        if not vendor_number:
            return frozenset()
        match_dict = dictionary_create(
            None, (ptr * 1)(key("VendorID")), (ptr * 1)(vendor_number), 1,
            ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryKeyCallBacks")),
            ctypes.addressof(ctypes.c_char.in_dll(cf, "kCFTypeDictionaryValueCallBacks")),
        )
        if not match_dict:
            return frozenset()
        matching(manager, match_dict)
        loop = run_loop()
        schedule(manager, loop, run_mode)
        scheduled = True
        opened = open_manager(manager, 0) == 0
        if not opened:
            return frozenset()
        run_for(run_mode, 0.2, False)
        devices = copy_devices(manager)
        if not devices:
            return frozenset()
        count = set_count(devices)
        if not 0 <= count <= 256:
            return frozenset()
        values = (ptr * count)()
        set_values(devices, values)
        for device in values:
            vendor = number(property_value(device, key("VendorID")))
            product = number(property_value(device, key("ProductID")))
            if vendor != 0x303A or product not in {0x8297, 0x8298}:
                continue
            serial = text(property_value(device, key("SerialNumber")))
            transport = {"USB": 1, "Bluetooth": 2}.get(text(property_value(device, key("Transport"))))
            pairs = property_value(device, key("DeviceUsagePairs"))
            if not serial or transport is None or not pairs or get_type(pairs) != type_array:
                continue
            for index in range(min(32, max(0, array_count(pairs)))):
                pair = array_value(pairs, index)
                if pair and get_type(pair) == type_dictionary and (
                        number(dictionary_value(pair, key("DeviceUsagePage"))) == 0xFF00
                        and number(dictionary_value(pair, key("DeviceUsage"))) == 1):
                    found.add((vendor, product, serial, transport))
    finally:
        if devices:
            release(devices)
        if scheduled:
            unschedule(manager, loop, run_mode)
        if opened:
            close_manager(manager, 0)
        if manager:
            release(manager)
        if match_dict:
            release(match_dict)
        if vendor_number:
            release(vendor_number)
        for value in keys.values():
            if value:
                release(value)
    return frozenset(found)


def preferred_endpoints(devices: list[dict]) -> list[dict]:
    """Collapse proven USB/Bluetooth duplicates, never ambiguous same-bus identities."""
    output = []
    serials = {row.get("serial_number") for row in devices if isinstance(row.get("serial_number"), str)}
    for serial in sorted(serials):
        rows = [row for row in devices if row.get("serial_number") == serial]
        if len(rows) == 2 and {row.get("bus_type") for row in rows} == {1, 2}:
            rows = [row for row in rows if row.get("bus_type") == 1]
        output.extend(rows)
    output.extend(row for row in devices if not isinstance(row.get("serial_number"), str))
    return output
