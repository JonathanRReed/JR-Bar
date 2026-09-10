"""Entry point for the bundled ``jrbar-core`` helper.

PyInstaller freezes this file into ``JR-Bar.app/Contents/Helpers/jrbar-core``.
The one binary serves every command the Swift app and the owner need:

    jrbar-core core                        # the daemon the app supervises
    jrbar-core agent-monitor install all   # every provider's hooks -> the bundled shim
    jrbar-core hooks doctor
    jrbar-core doctor

It is the public ``jrbar`` CLI router, nothing more. The old no-argument
branch that started the PyObjC status bar is gone: the Swift app is the UI.
"""

from __future__ import annotations

import sys

from jrbar.cli_entry import jrbar_main


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "-m":
        # `jrbar-core -m jrbar.hook_client ...` behaves like
        # `python -m jrbar.hook_client ...` so hook commands registered for
        # an interpreter keep working when they name this binary instead.
        import runpy

        if len(sys.argv) < 3:
            print("usage: jrbar-core -m <module> [args...]", file=sys.stderr)
            return 2
        module = sys.argv[2]
        sys.argv = [module, *sys.argv[3:]]
        runpy.run_module(module, run_name="__main__", alter_sys=True)
        return 0
    return jrbar_main()


if __name__ == "__main__":
    raise SystemExit(main())
