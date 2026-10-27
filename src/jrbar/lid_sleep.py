from __future__ import annotations

import getpass
import os
import re
import shlex
import shutil
import subprocess
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path

from .power_policy import configure_caffeinate_display_assertion, display_hold_wanted
from .settings import (
    CLOSED_LID_AWAKE_AGENTS,
    CLOSED_LID_AWAKE_ALWAYS,
    CLOSED_LID_AWAKE_NEVER,
)

# -t bounds the assertion by TIME as well as by process life: the hold
# is renewed by the app's sync tick, and a hold whose renewals stopped
# (App Nap with the display asleep, a wedge, a bootout) must die on its
# own instead of burning a closed laptop all night.
CAFFEINATE_SELF_EXPIRE_SECONDS = 1800
CAFFEINATE_CLOSED_LID_COMMAND = (
    "/usr/bin/caffeinate",
    "-ims",
    "-t",
    str(CAFFEINATE_SELF_EXPIRE_SECONDS),
)
#: The watchdog clears disablesleep when the renewal file goes stale.
RENEWAL_FILE_NAME = "lid-hold-renewal"
#: The watchdog records its pid here so a new spawn reclaims the role
#: (kill the recorded predecessor) instead of stacking beside it.
WATCHDOG_PID_FILE_NAME = "lid-hold-watchdog.pid"
#: Three minutes without a renewal clears the hold. With the poll below, a
#: Mac whose daemon died is sleepable again within about four minutes.
RENEWAL_STALE_SECONDS = 180
#: The renewal file is touched at most this often. Staleness is three
#: minutes, and the hold is asked to renew on every refresh (several a
#: second while agents work), so touching on every ask only wrote the disk.
RENEWAL_TOUCH_SECONDS = 30
WATCHDOG_POLL_SECONDS = 60
#: A renewal stamped further ahead than this is not a heartbeat (a clock
#: step or a forged mtime) and counts as stale, so it cannot pin the hold.
RENEWAL_FUTURE_TOLERANCE_SECONDS = 60
IOREG_CLAMSHELL_COMMAND = ("/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "4")
IOREG_SLEEP_DISABLED_COMMAND = ("/usr/sbin/ioreg", "-r", "-k", "SleepDisabled", "-d", "4")
# True when shutting the lid puts the Mac to sleep -- no external display
# is keeping it in clamshell mode. The one fact that separates "a laptop in
# a bag" from "a laptop closed on a desk driving a monitor".
IOREG_CLAMSHELL_CAUSES_SLEEP_COMMAND = (
    "/usr/sbin/ioreg",
    "-r",
    "-k",
    "AppleClamshellCausesSleep",
    "-d",
    "4",
)
PMSET_SLEEP_NOW_COMMAND = ("/usr/bin/pmset", "sleepnow")
SUDO_PMSET_DISABLE_SLEEP_COMMAND = (
    "/usr/bin/sudo",
    "-n",
    "/usr/bin/pmset",
    "-a",
    "disablesleep",
)
SLEEP_HELPER_SUDOERS_PATH = Path("/etc/sudoers.d/jrbar-disablesleep")
# Rule file written before the JR-Bar rename; status and uninstall honour it.
LEGACY_SLEEP_HELPER_SUDOERS_PATH = Path("/etc/sudoers.d/sidepulse-disablesleep")
SLEEP_HELPER_SUDOERS_PATHS = (SLEEP_HELPER_SUDOERS_PATH, LEGACY_SLEEP_HELPER_SUDOERS_PATH)
LID_POLL_SECONDS = 1.0


CommandRunner = Callable[..., subprocess.CompletedProcess]


@dataclass(frozen=True)
class SleepHelperInstallResult:
    path: Path
    user: str
    changed: bool
    installed: bool
    dry_run: bool = False


class SleepHelperRequiredError(RuntimeError):
    pass


def closed_lid_awake_should_hold(policy: str, *, agents_active: bool) -> bool:
    if policy == CLOSED_LID_AWAKE_ALWAYS:
        return True
    if policy == CLOSED_LID_AWAKE_AGENTS:
        return agents_active
    return False


_IOKIT_BINDINGS = None
_IOKIT_BINDINGS_FAILED = False


def _iokit_bindings():
    """IOKit and CoreFoundation, loaded and given their prototypes once.

    The lid poll reads three properties on a timer, and finding and loading
    the two frameworks again for each read (``find_library`` walks the dyld
    cache's candidate paths) cost more than the read. None when the
    frameworks cannot be loaded; that is remembered, so a Mac without them
    does not retry every second."""
    global _IOKIT_BINDINGS, _IOKIT_BINDINGS_FAILED
    if _IOKIT_BINDINGS is not None:
        return _IOKIT_BINDINGS
    if _IOKIT_BINDINGS_FAILED:
        return None
    try:
        import ctypes
        import ctypes.util

        iokit = ctypes.cdll.LoadLibrary(ctypes.util.find_library("IOKit"))
        cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
        iokit.IOServiceMatching.restype = ctypes.c_void_p
        iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
        iokit.IOServiceGetMatchingService.restype = ctypes.c_uint32
        iokit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        iokit.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
        iokit.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
        iokit.IOObjectRelease.argtypes = [ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFBooleanGetValue.restype = ctypes.c_bool
        cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
        cf.CFGetTypeID.restype = ctypes.c_ulong
        cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
        cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
        cf.CFRelease.argtypes = [ctypes.c_void_p]
    except (OSError, TypeError, AttributeError):
        _IOKIT_BINDINGS_FAILED = True
        return None
    _IOKIT_BINDINGS = (iokit, cf)
    return _IOKIT_BINDINGS


def _iokit_root_domain_bool(property_name: str) -> bool | None:
    """Read a boolean off IOPMrootDomain in-process through IOKit — the
    same answer ``ioreg`` prints, without forking a process for it. The
    lid poll asked every couple of seconds, and each ``ioreg`` fork was
    ~50 ms of CPU on an idle desk (measured 2026-09-16). None when IOKit
    is unavailable or the property is absent; callers fall back to
    ``ioreg`` then."""
    bindings = _iokit_bindings()
    if bindings is None:
        return None
    iokit, cf = bindings
    try:
        service = iokit.IOServiceGetMatchingService(0, iokit.IOServiceMatching(b"IOPMrootDomain"))
        if not service:
            return None
        try:
            key = cf.CFStringCreateWithCString(None, property_name.encode("utf-8"), 0x08000100)
            try:
                value = iokit.IORegistryEntryCreateCFProperty(service, key, None, 0)
            finally:
                cf.CFRelease(key)
            if not value:
                return None
            try:
                if cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID():
                    return None
                return bool(cf.CFBooleanGetValue(value))
            finally:
                cf.CFRelease(value)
        finally:
            iokit.IOObjectRelease(service)
    except (OSError, AttributeError, ValueError):
        return None


def read_lid_closed(
    *,
    runner: CommandRunner = subprocess.run,
    command: Sequence[str] = IOREG_CLAMSHELL_COMMAND,
) -> bool | None:
    if runner is subprocess.run and command is IOREG_CLAMSHELL_COMMAND:
        direct = _iokit_root_domain_bool("AppleClamshellState")
        if direct is not None:
            return direct
    result = runner(
        list(command),
        check=True,
        capture_output=True,
        text=True,
        timeout=2,
    )
    return parse_bool_ioreg_property(result.stdout, "AppleClamshellState")


def read_sleep_disabled(
    *,
    runner: CommandRunner = subprocess.run,
    command: Sequence[str] = IOREG_SLEEP_DISABLED_COMMAND,
) -> bool | None:
    if runner is subprocess.run and command is IOREG_SLEEP_DISABLED_COMMAND:
        direct = _iokit_root_domain_bool("SleepDisabled")
        if direct is not None:
            return direct
    result = runner(
        list(command),
        check=True,
        capture_output=True,
        text=True,
        timeout=2,
    )
    return parse_bool_ioreg_property(result.stdout, "SleepDisabled")


def read_clamshell_causes_sleep(
    *,
    runner: CommandRunner = subprocess.run,
    command: Sequence[str] = IOREG_CLAMSHELL_CAUSES_SLEEP_COMMAND,
) -> bool | None:
    if runner is subprocess.run and command is IOREG_CLAMSHELL_CAUSES_SLEEP_COMMAND:
        direct = _iokit_root_domain_bool("AppleClamshellCausesSleep")
        if direct is not None:
            return direct
    result = runner(
        list(command),
        check=True,
        capture_output=True,
        text=True,
        timeout=2,
    )
    return parse_bool_ioreg_property(result.stdout, "AppleClamshellCausesSleep")


class SystemSleepSuppressedError(RuntimeError):
    """This process must never put the Mac to sleep (the test sandbox)."""


def system_sleep_suppressed() -> bool:
    """True inside the test sandbox. A test that walks a closed-lid release
    must never reach the real ``pmset sleepnow``: the machine running the
    suite may be the one a closed-lid hold is keeping awake right now."""
    from .env import env_value

    return env_value("JRBAR_TESTING") == "1" or "PYTEST_CURRENT_TEST" in os.environ


def run_pmset_sleepnow(*, runner: CommandRunner = subprocess.run) -> None:
    """Ask macOS to sleep now. ``pmset sleepnow`` needs no privilege, so the
    sudoers rule stays exactly the two ``disablesleep`` lines it grants."""
    if system_sleep_suppressed():
        raise SystemSleepSuppressedError("system sleep is suppressed in this process")
    result = runner(
        list(PMSET_SLEEP_NOW_COMMAND),
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip().splitlines()
        raise RuntimeError(f"pmset sleepnow failed{': ' + detail[0] if detail else ''}")


def parse_bool_ioreg_property(text: str | bytes, property_name: str) -> bool | None:
    if isinstance(text, bytes):
        text = text.decode("utf-8", errors="replace")
    pattern = rf'"{re.escape(property_name)}"\s*=\s*(Yes|No|true|false|1|0)'
    match = re.search(pattern, text, flags=re.IGNORECASE)
    if match is None:
        return None
    value = match.group(1).lower()
    if value in {"yes", "true", "1"}:
        return True
    if value in {"no", "false", "0"}:
        return False
    return None


def external_display_is_active() -> bool | None:
    try:
        from .native_displays import external_display_is_active as read

        return read()
    except Exception:
        return None


def run_pmset_displaysleepnow(*, runner: CommandRunner = subprocess.run) -> None:
    if system_sleep_suppressed():
        raise SystemSleepSuppressedError("display sleep is suppressed in this process")
    result = runner(["/usr/bin/pmset", "displaysleepnow"], check=False,
                    capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise RuntimeError("macOS refused display sleep")


def run_sudo_pmset_disablesleep(
    enabled: bool,
    *,
    runner: CommandRunner = subprocess.run,
) -> None:
    value = "1" if enabled else "0"
    command = [*SUDO_PMSET_DISABLE_SLEEP_COMMAND, value]
    result = runner(
        command,
        check=False,
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode == 0:
        return

    detail = (result.stderr or result.stdout or "").strip()
    if detail:
        detail = f" ({detail.splitlines()[0]})"
    raise SleepHelperRequiredError(
        "Lid-closed awake needs one-time setup: "
        f"{sleep_helper_install_command()}"
        f"{detail}"
    )


def sleep_helper_sudoers_rule(user: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", user):
        raise ValueError(f"invalid sudoers user: {user!r}")
    return (
        f"{user} ALL=(root) NOPASSWD: "
        "/usr/bin/pmset -a disablesleep 0, "
        "/usr/bin/pmset -a disablesleep 1\n"
    )


def sleep_helper_target_user() -> str:
    for value in (os.environ.get("SUDO_USER"), os.environ.get("USER")):
        if value:
            return value
    try:
        return os.getlogin()
    except OSError:
        return getpass.getuser()


def sleep_helper_installed(path: Path | None = None) -> bool:
    if path is not None:
        return path.exists()
    return any(candidate.exists() for candidate in SLEEP_HELPER_SUDOERS_PATHS)


def sleep_helper_install_command(executable: str = "jrbar") -> str:
    resolved = shutil.which(executable) or executable
    return f"sudo {shlex.quote(resolved)} status-bar install-sleep-helper"


def install_sleep_helper(
    *,
    user: str | None = None,
    path: Path = SLEEP_HELPER_SUDOERS_PATH,
    dry_run: bool = False,
    runner: CommandRunner = subprocess.run,
) -> SleepHelperInstallResult:
    target_user = user or sleep_helper_target_user()
    rule = sleep_helper_sudoers_rule(target_user)
    try:
        current = path.read_text(encoding="utf-8") if path.exists() else None
    except OSError:
        current = None
    changed = current != rule

    if dry_run:
        return SleepHelperInstallResult(
            path=path,
            user=target_user,
            changed=changed,
            installed=not changed,
            dry_run=True,
        )

    require_root_for_sleep_helper()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp_path.write_text(rule, encoding="utf-8")
        os.chown(tmp_path, 0, 0)
        os.chmod(tmp_path, 0o440)
        runner(
            ["/usr/sbin/visudo", "-cf", str(tmp_path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
        if changed:
            tmp_path.replace(path)
        else:
            tmp_path.unlink()
    except Exception:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        raise

    return SleepHelperInstallResult(
        path=path,
        user=target_user,
        changed=changed,
        installed=True,
    )


def uninstall_sleep_helper(
    *,
    path: Path | None = None,
    dry_run: bool = False,
) -> SleepHelperInstallResult:
    target_user = sleep_helper_target_user()
    # Remove the current rule and any pre-rename rule still on disk.
    targets = (path,) if path is not None else SLEEP_HELPER_SUDOERS_PATHS
    existing = tuple(candidate for candidate in targets if candidate.exists())
    path = targets[0]
    changed = bool(existing)
    if dry_run:
        return SleepHelperInstallResult(
            path=path,
            user=target_user,
            changed=changed,
            installed=changed,
            dry_run=True,
        )

    require_root_for_sleep_helper()
    for candidate in existing:
        candidate.unlink()
    return SleepHelperInstallResult(
        path=path,
        user=target_user,
        changed=changed,
        installed=False,
    )


def require_root_for_sleep_helper() -> None:
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        raise PermissionError(f"run once with sudo: {sleep_helper_install_command()}")


def _default_renewal_path() -> Path:
    from .providers import default_state_dir

    return default_state_dir() / RENEWAL_FILE_NAME


def watchdog_script(renewal_path: Path, pid_path: Path | None = None) -> str:
    """The detached fail-safe. Survives the app (new session), needs no
    Python, and has exactly one job: when the renewal heartbeat goes
    stale or vanishes, put the system back to sleepable and exit.

    The pidfile keeps at most one watchdog alive per marker. On startup
    the script kills whichever predecessor the pidfile records -- but
    only when that pid's command line still references this marker, so a
    stale pidfile or a recycled pid is left alone -- then writes its own
    pid. Each poll it re-reads the pidfile and exits the moment it names
    someone else (a newer watchdog took over, or a clean release removed
    it), so orphans from past daemon lifetimes cannot pile up."""
    quoted = shlex.quote(str(renewal_path))
    pidfile = shlex.quote(
        str(pid_path or renewal_path.with_name(WATCHDOG_PID_FILE_NAME))
    )
    return (
        # Reclaim: a watchdog orphaned by a previous daemon lifetime is
        # still looping on this same marker. Its /bin/sh -c command text
        # embeds the marker path -- that is the same-script sanity check
        # before killing the recorded pid.
        f"old=$(cat {pidfile} 2>/dev/null)\n"
        f"case \"$old\" in ''|*[!0-9]*) old= ;; esac\n"
        f"if [ -n \"$old\" ] && [ \"$old\" != \"$$\" ]; then\n"
        f"  if kill -0 \"$old\" 2>/dev/null"
        f" && ps -p \"$old\" -o command= 2>/dev/null"
        f" | grep -F {quoted} >/dev/null 2>&1; then\n"
        f"    kill \"$old\" 2>/dev/null\n"
        f"  fi\n"
        f"fi\n"
        # Orphan sweep: watchdogs spawned before the pidfile existed
        # recorded nothing, so the pidfile reclaim can never reach them.
        # Their /bin/sh -c command text still embeds the marker path --
        # kill every match but this shell. At most one watchdog may loop
        # on a marker, and the ones that predate the file are all
        # predecessors by definition.
        f"for orphan in $(pgrep -f {quoted} 2>/dev/null); do\n"
        f"  [ \"$orphan\" != \"$$\" ] && kill \"$orphan\" 2>/dev/null\n"
        f"done\n"
        f"echo $$ > {pidfile}\n"
        f"while true; do\n"
        f"  sleep {WATCHDOG_POLL_SECONDS}\n"
        # Superseded -- the pidfile names another watchdog, or a clean
        # release removed it: bow out without touching anything.
        f"  if [ \"$(cat {pidfile} 2>/dev/null)\" != \"$$\" ]; then exit 0; fi\n"
        f"  if [ ! -f {quoted} ]; then rm -f {pidfile}; exit 0; fi\n"
        f"  now=$(date +%s)\n"
        f"  mt=$(stat -f %m {quoted} 2>/dev/null || echo 0)\n"
        f"  age=$((now - mt))\n"
        f"  if [ \"$age\" -gt {RENEWAL_STALE_SECONDS} ]"
        f" || [ \"$age\" -lt -{RENEWAL_FUTURE_TOLERANCE_SECONDS} ]; then\n"
        f"    /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null\n"
        f"    rm -f {quoted} {pidfile}\n"
        f"    exit 0\n"
        f"  fi\n"
        f"done\n"
    )


class ClosedLidAwakeController:
    def __init__(
        self,
        *,
        command: Sequence[str] = CAFFEINATE_CLOSED_LID_COMMAND,
        process_factory: Callable[..., object] | None = None,
        sleep_disabled_reader: Callable[[], bool | None] = read_sleep_disabled,
        sleep_disabled_setter: Callable[[bool], None] = run_sudo_pmset_disablesleep,
        watch_current_process: bool = True,
        use_system_disable: bool = False,
        renewal_path: Path | None = None,
        watchdog_pid_path: Path | None = None,
        keep_display_awake: bool = False,
    ) -> None:
        self.command = tuple(command)
        self.process_factory = process_factory or subprocess.Popen
        self.sleep_disabled_reader = sleep_disabled_reader
        self.sleep_disabled_setter = sleep_disabled_setter
        self.watch_current_process = watch_current_process
        self.use_system_disable = use_system_disable
        self.keep_display_awake = bool(keep_display_awake)
        self.process = None
        self._process_display: bool | None = None
        self.changed_system_disable = False
        self.system_disable_attempted = False
        self.orphan_reclaim_attempted = False
        self.last_error: str | None = None
        self.last_policy = CLOSED_LID_AWAKE_NEVER
        self.last_requested = False
        self.renewal_path = renewal_path or _default_renewal_path()
        self.watchdog_pid_path = (
            watchdog_pid_path
            if watchdog_pid_path is not None
            else self.renewal_path.with_name(WATCHDOG_PID_FILE_NAME)
        )
        self.watchdog_process = None
        self._watchdog_retiring = False
        # Wired by the daemon (configure_sleep_on_release); inert otherwise,
        # so the menu-bar app and every test that builds one of these keeps
        # the release behaviour it always had.
        self.governor: Callable[[], str | None] | None = None
        self.power_log = None
        self.lid_closed_reader: Callable[[], bool | None] | None = None
        self.clamshell_sleep_reader: Callable[[], bool | None] | None = None
        self.sleeper: Callable[[], None] | None = None
        self.wall_clock: Callable[[], float] = time.time
        self.held_since: float | None = None
        self._pending_release_reason: str | None = None
        self.last_release_reason: str | None = None
        self.last_sleep_epoch: float | None = None
        self.last_sleep_error: str | None = None
        self.external_display_reader: Callable[[], bool | None] = external_display_is_active
        self.display_sleeper: Callable[[], None] = run_pmset_displaysleepnow
        self._display_sleep_requested = False
        self._display_sleep_retry_at = 0.0
        #: The lid as the daemon last read it (``observe_lid``); None while
        #: nothing reads it, which counts as open.
        self.lid_closed: bool | None = None

    def observe_lid(self, lid_closed: bool | None) -> None:
        """The lid reading before each update: with the lid shut on no
        external display the hold lets the display sleep."""
        self.lid_closed = lid_closed if isinstance(lid_closed, bool) else None

    def display_wanted(self) -> bool:
        """``keep_display_awake``, except with the lid shut and no external
        display on: then the computer stays awake and the screen sleeps."""
        if not self.keep_display_awake:
            return False
        external = self._read(self.external_display_reader) if self.lid_closed is True else None
        return display_hold_wanted(True, lid_closed=self.lid_closed, external_display=external)

    def configure_sleep_on_release(
        self,
        *,
        lid_closed_reader: Callable[[], bool | None],
        clamshell_sleep_reader: Callable[[], bool | None],
        sleeper: Callable[[], None],
    ) -> None:
        """Sleep explicitly when the hold drops with the lid shut.

        Releasing ``disablesleep`` leaves a shut, displayless laptop awake
        until macOS next re-checks the clamshell -- which may be never, on
        an idle machine with nothing to wake it. "Auto-sleep when the agents
        finish" is a promise, so the release asks for sleep in so many
        words, and only when both readings agree: the lid IS shut, and
        shutting it DOES mean sleep (no external display holding clamshell
        mode). An unreadable fact never sleeps the Mac."""
        self.lid_closed_reader = lid_closed_reader
        self.clamshell_sleep_reader = clamshell_sleep_reader
        self.sleeper = sleeper

    def set_use_system_disable(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if self.use_system_disable == enabled:
            return
        self.use_system_disable = enabled
        self.system_disable_attempted = False
        self.orphan_reclaim_attempted = False
        if not enabled:
            self.release_system_disable()

    def set_keep_display_awake(self, enabled: bool) -> None:
        enabled = bool(enabled)
        if self.keep_display_awake == enabled:
            return
        self.keep_display_awake = enabled
        was_running = self.process_running()
        if was_running:
            if self.last_requested:
                self.ensure_awake()
            else:
                errors: list[str] = []
                self._terminate_caffeinate(errors)
                self.last_error = "; ".join(errors) if errors else None

    def update(self, policy: str, *, agents_active: bool) -> bool:
        should_hold = closed_lid_awake_should_hold(policy, agents_active=agents_active)
        # Heat and a dying battery outrank even "Always stay awake": that
        # policy means "while it is safe", and a laptop cooking in a bag or
        # about to die mid-write is not.
        suspension = self._suspension()
        if suspension is not None:
            should_hold = False
        was_requested = self.last_requested
        policy_changed = policy != self.last_policy
        if policy_changed:
            self.system_disable_attempted = False
        self.last_policy = policy
        self.last_requested = should_hold
        if should_hold:
            self._pending_release_reason = None
            if self.held_since is None:
                self.held_since = self.wall_clock()
            self.ensure_awake()
        else:
            if was_requested:
                self._pending_release_reason = (
                    suspension
                    or ("policy" if policy_changed and policy == CLOSED_LID_AWAKE_NEVER else "agents_idle")
                )
            self.release()
            if self._pending_release_reason is not None and not self.active():
                reason = self._pending_release_reason
                self._pending_release_reason = None
                self._after_release(reason)
        return self.active()

    def sync_display_sleep(self, *, lid_closed: bool | None) -> None:
        if lid_closed is not True or not self.last_requested:
            self._display_sleep_requested = False
            self._display_sleep_retry_at = 0.0
            return
        if self._display_sleep_requested or self.wall_clock() < self._display_sleep_retry_at:
            return
        if not self.changed_system_disable and self._read(self.sleep_disabled_reader) is not True:
            return
        if self._read(self.external_display_reader) is not False:
            return
        try:
            self.display_sleeper()
            self._display_sleep_requested = True
        except Exception:
            self._display_sleep_retry_at = self.wall_clock() + 30
            self.last_error = "; ".join(filter(None, (self.last_error, "Closed-lid display sleep failed")))

    def _suspension(self) -> str | None:
        governor = self.governor
        if governor is None:
            return None
        try:
            reason = governor()
        except Exception:
            return None
        return reason if isinstance(reason, str) and reason else None

    @staticmethod
    def _read(reader: Callable[[], bool | None] | None) -> bool | None:
        if reader is None:
            return None
        try:
            value = reader()
        except Exception:
            return None
        return value if isinstance(value, bool) else None

    def _after_release(self, reason: str) -> None:
        """Record the held stretch and, with the lid shut and nothing to
        keep clamshell mode, put the Mac to sleep."""
        now = self.wall_clock()
        held_for = None if self.held_since is None else max(0.0, now - self.held_since)
        self.held_since = None
        self.last_release_reason = reason
        lid_closed = self._read(self.lid_closed_reader)
        if lid_closed is not True:
            return
        self._log("lid_hold_ended", reason=reason, duration=held_for)
        if self.sleeper is None or self._read(self.clamshell_sleep_reader) is not True:
            return
        try:
            self.sleeper()
        except Exception as exc:
            self.last_sleep_error = str(exc) or exc.__class__.__name__
            return
        self.last_sleep_error = None
        self.last_sleep_epoch = now
        self._log("slept", reason=reason)

    def _log(self, kind: str, *, reason: str | None = None, duration: float | None = None) -> None:
        log = self.power_log
        record = getattr(log, "record", None)
        if not callable(record):
            return
        try:
            record(kind, reason=reason, duration=duration)
        except ValueError:
            pass

    def _renewal_is_fresh(self) -> bool:
        """True when the renewal file exists and was touched a moment ago, so
        another touch would change nothing the watchdog can see."""
        try:
            age = self.wall_clock() - self.renewal_path.stat().st_mtime
        except OSError:
            return False
        return 0.0 <= age < RENEWAL_TOUCH_SECONDS

    def _renew_heartbeat(self, errors: list[str]) -> bool:
        """Touch the renewal file and keep the fail-safe watchdog alive.
        True when both are in place, which is the only state in which
        `disablesleep` may be turned on."""
        if self._watchdog_retiring:
            self._retire_watchdog(errors)
            if self.watchdog_process is not None:
                return False
        try:
            if not self._renewal_is_fresh():
                self.renewal_path.parent.mkdir(parents=True, exist_ok=True)
                self.renewal_path.touch()
        except OSError as exc:
            errors.append(f"renewal: {exc}")
            return False
        watchdog = self.watchdog_process
        if watchdog is not None and watchdog.poll() is None:
            return True
        try:
            # The script itself reclaims the role: its first act is to
            # kill the watchdog the pidfile records (same-script sanity
            # check inside), so a new hold or a new daemon session can
            # never stack a second loop on this marker.
            self.watchdog_process = self.process_factory(
                [
                    "/bin/sh",
                    "-c",
                    watchdog_script(self.renewal_path, self.watchdog_pid_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        except Exception as exc:
            self.watchdog_process = None
            errors.append(f"watchdog: {exc}")
            return False
        return True

    def ensure_awake(self) -> None:
        errors: list[str] = []
        # The heartbeat comes FIRST: even if everything below fails, a
        # running watchdog with a fresh renewal is what guarantees the
        # system can always fall back asleep on its own. Without it,
        # `disablesleep` stays off: a daemon that dies afterwards would
        # leave a shut laptop awake with nothing to turn it back.
        failsafe_ready = self._renew_heartbeat(errors)
        if (
            failsafe_ready
            and self.use_system_disable
            and not self.changed_system_disable
            and not self.system_disable_attempted
        ):
            self.system_disable_attempted = True
            try:
                already_disabled = self.sleep_disabled_reader()
                if already_disabled is False or already_disabled is None:
                    self.sleep_disabled_setter(True)
                    self.changed_system_disable = True
            except Exception as exc:
                errors.append(f"disablesleep: {exc}")

        display = self.display_wanted()
        if self.process_running() and self._process_display != display:
            self._terminate_caffeinate(errors)
        if not self.process_running():
            try:
                self.process = self.process_factory(
                    self.caffeinate_command(display=display),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                self._process_display = display
            except Exception as exc:
                self.process = None
                errors.append(f"caffeinate: {exc}")

        self.last_error = "; ".join(errors) if errors else None

    def release(self) -> None:
        errors: list[str] = []
        self._terminate_caffeinate(errors)
        self.release_system_disable(errors=errors)
        if self.changed_system_disable:
            # `disablesleep` is still on (the helper refused). The renewal
            # file and the watchdog are the only thing left that can turn
            # it off, so they stay: the watchdog clears it once the file
            # goes stale, and the next release retries.
            self.last_error = "; ".join(errors) if errors else None
            return
        # Clean release retires the heartbeat and the watchdog pidfile;
        # any watchdog still looping exits on its next poll (marker gone
        # or pidfile no longer naming it) without touching anything.
        try:
            self.renewal_path.unlink(missing_ok=True)
        except OSError:
            pass
        self._retire_watchdog(errors)

        self.last_error = "; ".join(errors) if errors else None

    def _retire_watchdog(self, errors: list[str]) -> None:
        """A normal release leaves no watchdog behind: unlink the pidfile
        (a watchdog we did not spawn exits on its next poll when the file
        no longer names it) and stop the one we spawned right away."""
        try:
            self.watchdog_pid_path.unlink(missing_ok=True)
        except OSError:
            pass
        process = self.watchdog_process
        if process is None:
            self._watchdog_retiring = False
            return
        self._watchdog_retiring = True
        if self._stop_process(process, "watchdog", errors):
            self.watchdog_process = None
            self._watchdog_retiring = False

    def _terminate_caffeinate(self, errors: list[str]) -> None:
        process = self.process
        if process is None:
            return
        if self._stop_process(process, "caffeinate", errors):
            self.process = None
            self._process_display = None

    @staticmethod
    def _stop_process(process: object, name: str, errors: list[str]) -> bool:
        failure = None
        try:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=1)
        except Exception as exc:
            failure = exc
            try:
                process.kill()
                process.wait(timeout=1)
            except Exception as exc:
                failure = exc
        try:
            if process.poll() is not None:
                return True
        except Exception as exc:
            failure = exc
        detail = str(failure) if failure is not None else "process is still running"
        errors.append(f"{name}: could not stop: {detail}")
        return False

    def release_system_disable(self, *, errors: list[str] | None = None) -> None:
        active_errors = errors if errors is not None else []
        if self.changed_system_disable:
            try:
                self.sleep_disabled_setter(False)
                self.changed_system_disable = False
                self.system_disable_attempted = False
            except Exception as exc:
                active_errors.append(f"disablesleep: {exc}")
        else:
            self.system_disable_attempted = False
            # Orphan reclaim: a previous instance that set disablesleep and
            # was then killed (launchctl bootout, crash) never ran release,
            # and this instance's changed_system_disable knows nothing of
            # it -- the Mac stayed sleepless for a full day exactly this
            # way. With the helper installed, the flag belongs to this
            # feature: when we are NOT holding and the system still says
            # sleep is disabled, clear it. Checked once per process (and
            # again if the helper toggles) -- ioreg is a subprocess and
            # this runs on every sync.
            if self.use_system_disable and not self.orphan_reclaim_attempted:
                try:
                    if self.sleep_disabled_reader() is True:
                        self.changed_system_disable = True
                        self.sleep_disabled_setter(False)
                        self.changed_system_disable = False
                    self.orphan_reclaim_attempted = True
                except Exception as exc:
                    active_errors.append(f"disablesleep: {exc}")

        if errors is None:
            self.last_error = "; ".join(active_errors) if active_errors else None

    def active(self) -> bool:
        return self.process_running() or self.changed_system_disable

    def process_running(self) -> bool:
        return self.process is not None and self.process.poll() is None

    def caffeinate_command(self, *, display: bool | None = None) -> list[str]:
        command = list(
            configure_caffeinate_display_assertion(
                self.command,
                keep_display_awake=self.display_wanted() if display is None else display,
            )
        )
        if self.watch_current_process:
            command.extend(["-w", str(os.getpid())])
        return command
