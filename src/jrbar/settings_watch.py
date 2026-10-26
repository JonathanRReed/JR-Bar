"""Watch settings directories so atomic file replacement is also observed."""
from __future__ import annotations

import os
import select
import threading
import time
from pathlib import Path

SAFETY_POLL_SECONDS = 30.0


class SettingsWatcher:
    def __init__(self, paths, *, clock=time.monotonic, start=True):
        self.paths = tuple(Path(path) for path in paths)
        self._clock = clock
        self._dirty = threading.Event()
        self._dirty.set()
        self._stop = threading.Event()
        self._ready = threading.Event()
        self._next_poll = 0.0
        self._queue = None
        self._thread = None
        if start and hasattr(select, "kqueue"):
            self._thread = threading.Thread(target=self._run, name="JRBarSettingsWatch", daemon=True)
            self._thread.start()

    def changed(self, *, now=None):
        at = self._clock() if now is None else now
        if not self._dirty.is_set() and at < self._next_poll:
            return False
        self._dirty.clear()
        self._next_poll = at + SAFETY_POLL_SECONDS
        return True

    def close(self):
        self._stop.set()
        queue = self._queue
        if queue is not None:
            try:
                queue.close()
            except OSError:
                pass

    def _run(self):
        descriptors = {}
        queue = select.kqueue()
        self._queue = queue
        try:
            while not self._stop.is_set():
                parents = set()
                for path in self.paths:
                    parent = path.parent
                    while not parent.exists() and parent != parent.parent:
                        parent = parent.parent
                    parents.add(parent)
                # Re-arm after rename or directory creation. Watching the
                # directory catches saves that replace the file's inode.
                for parent in parents - descriptors.keys():
                    fd = None
                    try:
                        fd = os.open(parent, os.O_EVTONLY)
                        event = select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                            flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                            fflags=select.KQ_NOTE_WRITE | select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE | select.KQ_NOTE_ATTRIB)
                        queue.control([event], 0, 0)
                    except OSError:
                        if fd is not None:
                            os.close(fd)
                        continue
                    descriptors[parent] = fd
                for parent in descriptors.keys() - parents:
                    os.close(descriptors.pop(parent))
                self._ready.set()
                events = queue.control(None, max(1, len(descriptors)), SAFETY_POLL_SECONDS)
                if events:
                    self._dirty.set()
                    for event in events:
                        if event.fflags & (select.KQ_NOTE_RENAME | select.KQ_NOTE_DELETE):
                            for parent, fd in list(descriptors.items()):
                                if fd == event.ident:
                                    os.close(descriptors.pop(parent))
        except (OSError, ValueError):
            self._dirty.set()  # the slow poll still recovers a lost watch
        finally:
            self._queue = None
            for fd in descriptors.values():
                os.close(fd)
            try:
                queue.close()
            except OSError:
                pass
