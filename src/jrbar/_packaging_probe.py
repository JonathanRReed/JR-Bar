"""Run the frozen daemon in an isolated home for the packaging verifier."""
from __future__ import annotations

import ctypes as c
import json
import os
import socket
import sys
import time
from pathlib import Path

FORBIDDEN_MODULES = frozenset({"objc", "AppKit", "Cocoa", "Foundation", "WebKit", "Quartz", "EventKit", "JavaScriptCore"})


def forbidden_images(images):
    return sorted(name for name in images if any(marker in name.lower() for marker in
                  ("/appkit.framework/", "/webkit.framework/", "/webkitlegacy.framework/", "/objc/_", "pyobjc")))


def inventory():
    lib = c.CDLL("/usr/lib/libSystem.B.dylib")
    lib._dyld_image_count.restype = c.c_uint32
    lib._dyld_get_image_name.argtypes = [c.c_uint32]
    lib._dyld_get_image_name.restype = c.c_char_p
    images = [lib._dyld_get_image_name(index).decode() for index in range(lib._dyld_image_count())]
    modules = sorted(sys.modules)
    return {"images": images, "modules": modules,
            "forbidden_images": forbidden_images(images),
            "forbidden_modules": [name for name in modules if name.split(".")[0] in FORBIDDEN_MODULES]}


def run(root: Path) -> int:
    root = root.resolve(strict=True)
    if Path.home().resolve() != root or os.environ.get("JRBAR_TESTING") != "1":
        raise RuntimeError("packaging probe requires its own temporary HOME and JRBAR_TESTING=1")
    for variable, leaf in (("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("XDG_CACHE_HOME", "cache")):
        if Path(os.environ.get(variable, "/")).resolve() != root / leaf:
            raise RuntimeError("packaging probe requires isolated XDG directories")

    def guard(event, args):
        if event == "subprocess.Popen":
            raise OSError("packaging probe refuses external commands")
        if event == "socket.connect":
            if args[0].family != socket.AF_UNIX or not Path(os.fsdecode(args[1])).resolve().is_relative_to(root):
                raise OSError("packaging probe permits only sockets in its temporary HOME")
        if event == "open" and isinstance(args[0], (str, bytes, os.PathLike)):
            flags = args[2]
            if flags & (os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND):
                path = Path(os.fsdecode(args[0])).resolve()
                if not path.is_relative_to(root) and path != Path("/dev/null"):
                    raise OSError("packaging probe refuses writes outside its temporary HOME")

    sys.addaudithook(guard)
    from . import core_runtime, daemon_controller
    from .cli_entry import jrbar_main
    from .daemon_loop import Timer, application
    from .memory_probe import resident_bytes

    daemon_controller.discover_devices = lambda **_: []
    build = core_runtime.build_headless_controller_class

    def headless_class():
        cls = build()
        cls._core_deck_probe_now = lambda self: None
        return cls

    core_runtime.build_headless_controller_class = headless_class
    samples = []
    outcome = []
    started = time.monotonic()

    class Observer:
        def sample_(self, timer):
            controller = application().delegate
            fallback = controller._core_environment_fallback
            samples.append({"rss_bytes": resident_bytes(), "elapsed_seconds": time.monotonic() - started,
                            "fallback_active": fallback is not None and fallback.native is not None})
            if len(samples) < 4:
                return
            timer.invalidate()
            receipt = inventory()
            receipt.update(schema=1, frozen=bool(getattr(sys, "frozen", False)), pid=os.getpid(), samples=samples,
                           socket_ready=controller._core is not None and controller._core.socket_path == root / "core.sock"
                           and (root / "core.sock").is_socket())
            (root / "runtime.json").write_text(json.dumps(receipt, indent=2) + "\n")
            outcome.append(receipt)
            application().terminate_(None)

    observer = Observer()
    timer = Timer.timerWithTimeInterval_target_selector_userInfo_repeats_(1.0, observer, "sample:", None, True)
    timer.setFireDate_(time.monotonic() + 6.0)
    application().add_timer(timer)
    result = jrbar_main(["core", "--socket", str(root / "core.sock")])
    return result if result else (0 if outcome else 1)


if __name__ == "__main__":
    raise SystemExit(run(Path(sys.argv[1])))
